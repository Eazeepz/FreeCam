-- Free Camera - press Insert to take the camera off the player and park it.
--
-- The game's third-person camera lives at 0x827D9778. +56 is the position the
-- follow camera (0x8210D518) wants, +44 is the position actually drawn, and
-- +80/+92/+104 are the orientation rows right/up/forward.
--
-- TWO functions have to be cut, not one. An earlier version cut only the camera
-- manager (0x82109608) and the camera still slid around with the player:
-- sub_8210D518 is what aims at the player and resolves camera collision against
-- them every frame, so it has to be cut as well. The position is written from
-- the follow camera hook, which is the one the game calls every frame. The port's
-- Studio camera does exactly this (kbm.cpp:812-818) and writes the same five
-- slots (world_studio_bridge.cpp, WriteEditorCamera).
--
-- Cutting a hook rather than wrapping it is why this and AltCameraModes still
-- chain: with the free camera off, ctx:call_original() runs and AltCameraModes
-- behaves exactly as it does now.

local CAMERA         = 0x827D9778
local CAMERA_UPDATE  = 0x82109608   -- the camera manager: the place it is drawn
local FOLLOW_CAMERA  = 0x8210D518   -- the third-person follow camera
local FRAME_TIME     = 0x827AA6C8   -- raw frame time in seconds

-- World freeze, from the same three guest values the port's World Studio uses
-- for its own pause (world_studio_bridge.cpp:1616-1631, UpdateWorldPause).
-- Raising the time divisor to 100000 with the fixed-step flag set and the rate
-- at a million makes the simulation stand still while the game keeps running
-- frames, so the renderer -- and this camera -- carry on and you can still
-- compose the shot. The port also slows the host clock and pauses audio from
-- C++; neither is reachable from Lua, so sound keeps playing and anything driven
-- by mftb rather than game time still creeps. Holding the cutscene clock covers
-- what the port's own comment calls the visible part.
local TIME_DIVISOR   = 0x827AA6D4   -- f32
local FIXED_STEP     = 0x836FD673   -- u8
local FIXED_RATE     = 0x827D6D30   -- f32
local CUTSCENE_CLK_A = 0x8370DC48   -- u32
local CUTSCENE_CLK_B = 0x8370DC4C   -- u32
local FROZEN_DIVISOR, FROZEN_RATE = 100000.0, 1000000.0

local POS, LOOK_POS          = CAMERA + 44, CAMERA + 56
local RIGHT, UP, FORWARD     = CAMERA + 80, CAMERA + 92, CAMERA + 104

local fly_key = wml.setting("key", "INSERT")
local speed   = wml.setting("speed", 8.0)          -- metres per second
local fast    = wml.setting("fast_multiplier", 4.0)
local slow    = wml.setting("slow_multiplier", 0.25)
local look    = wml.setting("look_speed", 1.0)    -- scales mouse_look
local pitch_limit = wml.setting("pitch_limit", 86.0)  -- degrees
-- wml.mouse_look() already has the game's own "invert Y" option applied to it
-- (the port flips it at kbm.cpp:772 before mods ever see it), so the mod is
-- consistent with the player camera out of the box. This is a second flip on
-- top, for people who want the free camera the other way round.
-- Settings arrive as strings, so compare: the string "false" is truthy in Lua.
local invert_y    = (wml.setting("invert_y", "true") == "true")
local show_help   = (wml.setting("show_help", "true") == "true")
-- Only works while the free camera is on: see the note in on_frame.
local pause_key  = wml.setting("pause_key", "F2")
-- Shows or hides this list in the corner.
local help_key   = wml.setting("help_key", "F7")



-- Caps Lock needs help to be a key. The loader's KeyFromName has no entry for
-- it, and every setting arrives as a string (OpenWmlLibrary pushes them all with
-- lua_pushstring), so `key = 20` would be parsed as F20, not VK_CAPITAL --
-- a silent wrong binding rather than an error. CheckKey does accept a raw
-- number, and UpdateKeys polls GetAsyncKeyState for every VK 1-255, so resolving
-- the name here makes Caps Lock a first-class key without touching the port.
local VK_CAPITAL = 0x14
local EXTRA_VK = {CAPS = VK_CAPITAL, CAPSLOCK = VK_CAPITAL}

local function vk_of(name)
  return EXTRA_VK[(name or ''):upper()] or name
end

-- Caps Lock is a toggle, and GetAsyncKeyState reports the resulting level, so
-- the second press is a falling edge -- which wml.key_pressed() deliberately
-- ignores. One press would switch the camera on and then never off again. So
-- watch the level change instead, which makes press one on and press two off.
--
-- Only a level change that holds for HOLD_FRAMES counts, so a single-frame
-- blip is ignored.
--
-- Losing window focus also drops the level to false and regaining it puts it
-- back, and there is no way to tell that from a press: key_down is focus-gated
-- (mod_loader.cpp:102), so from Lua the two are identical, and the loader
-- exposes no focus state at all. The consequence is that an alt-tab flips the
-- free camera once -- press Caps again to put it back. HOLD_FRAMES stops a
-- one-frame blip, nothing more; it cannot fix an indistinguishability.
local HOLD_FRAMES = 3
local toggle_level, toggle_hold = {}, {}

local function pressed(name)
  local up = (name or ''):upper()
  if not EXTRA_VK[up] then return wml.key_pressed(name) end
  local vk = vk_of(name)
  local down = wml.key_down(vk) and true or false
  if toggle_level[vk] == nil then toggle_level[vk] = down; return false end
  if down == toggle_level[vk] then toggle_hold[vk] = 0; return false end
  toggle_hold[vk] = (toggle_hold[vk] or 0) + 1
  if toggle_hold[vk] < HOLD_FRAMES then return false end
  toggle_hold[vk] = 0
  toggle_level[vk] = down
  return true
end
local held = {W = 'W', A = 'A', S = 'S', D = 'D', Q = 'Q', E = 'E'}

local seeded = false
local frozen = false
local keys_taken = false
local updated_this_frame = false
-- One key, three states: off, then flying freely, then locked in place.
-- OFF = 0, FREE = 1, LOCKED = 2. Pressing Insert steps to the next one.
local OFF, FREE, LOCKED = 0, 1, 2
local state = OFF
local saved = {}          -- what to put back when the world resumes
local x, y, z = 0.0, 0.0, 0.0
local yaw, pitch = 0.0, 0.0
-- The basis from the last unlocked frame, so the lock can keep writing
-- it. right/up/forward are locals built further down update_camera and
-- are nil when the lock engages.
local bx, by, bz = 0.0, 0.0, 1.0   -- forward
local ux, uy, uz = 0.0, 1.0, 0.0   -- up
local rx, ry, rz = 1.0, 0.0, 0.0   -- right

local function read_vec(addr)
  return wml.read_f32(addr), wml.read_f32(addr + 4), wml.read_f32(addr + 8)
end

local function write_vec(addr, a, b, c)
  wml.write_f32(addr, a); wml.write_f32(addr + 4, b); wml.write_f32(addr + 8, c)
end

-- wml.take_key is what stops the game seeing a key the mod is using. It used to
-- be gated on "camera on and right mouse held", so letting go of right mouse
-- handed the movement keys back while the camera was still on -- which reads as
-- "the camera locked the controls". The state is the only thing that gates it
-- now: the keys are held exactly while the camera can actually be moved.
local function take_fly_keys(taken)
  for _, k in pairs(held) do wml.take_key(k, taken) end
  -- Through vk_of, or a name the loader has no entry for silently takes
  -- nothing: CheckKey returns 0 and take_key rejects it, so the game would
  -- keep seeing the toggle key as well.
  wml.take_key(vk_of(fly_key), taken)
end

-- The follow camera has to be cut, not just the camera manager.
-- sub_8210D518 is what aims the camera at the player and resolves collisions
-- against the player every frame; leave it running and the camera slides with
-- them, which is exactly the "moves the position when the player moves" symptom.
-- The port's Studio camera cuts this one and writes from here (kbm.cpp:812-818,
-- WriteEditorCamera), and it writes the same five slots this mod does.
-- The camera update, factored out of either hook. Which of the two functions
-- the game actually calls in a given frame is not something to bet on: cutting
-- only the manager let the follow camera drag the camera along with the player,
-- and cutting only the follow camera left the camera immobile in the states
-- where the manager runs and the follow camera does not. So both drive this,
-- and `updated_this_frame` makes sure it still happens exactly once per frame
-- when they both fire.
local function update_camera()
  -- Read and discard the frame's mouse delta whether or not we use it, so
  -- turning the camera on does not apply a backlog of movement accumulated
  -- while it was off. wml.mouse_look() zeroes what it returns.
  local myaw, mpitch = wml.mouse_look()

  -- Locked: the camera is a fixed point in the world. The five vectors are
  -- still written every frame on purpose -- that is what makes the lock a lock
  -- rather than a pause. Something else touching the camera would otherwise
  -- still be free to move it, and the player would drift out of frame.
  if state == LOCKED then
    write_vec(POS, x, y, z)
    write_vec(LOOK_POS, x, y, z)
    write_vec(RIGHT, rx, ry, rz)
    write_vec(UP, ux, uy, uz)
    write_vec(FORWARD, bx, by, bz)
    return
  end

  if not seeded then
    x, y, z = read_vec(POS)
    local fx, fy, fz = read_vec(FORWARD)
    pitch = math.asin(math.max(-1.0, math.min(1.0, fy)))
    yaw = math.atan(fx, fz)   -- Lua spells atan2 as the two-argument atan
    seeded = true
    myaw, mpitch = 0.0, 0.0
  end

  local limit = pitch_limit * math.pi / 180.0
  yaw = yaw + myaw * look
  pitch = math.max(-limit, math.min(limit,
      pitch + mpitch * look * (invert_y and -1.0 or 1.0)))

  local cp = math.cos(pitch)
  local forward = {math.sin(yaw) * cp, math.sin(pitch), math.cos(yaw) * cp}
  local right   = {math.cos(yaw), 0.0, -math.sin(yaw)}
  local up      = {-math.sin(yaw) * math.sin(pitch), cp,
                   -math.cos(yaw) * math.sin(pitch)}

  local dt = wml.read_f32(FRAME_TIME)
  if dt ~= dt or dt <= 0.0 or dt > 0.5 then dt = 1.0 / 60.0 end

  -- State has already returned for LOCKED, so this only runs while flying.
  do
    local v = speed
    if wml.key_down("SHIFT") then v = v * fast end
    if wml.key_down("CONTROL") then v = v * slow end
    local step = v * dt
    -- wml.key_down returns a boolean, not 0/1, so fold it into a number here
    -- rather than comparing: true == 1 is false in Lua.
    local function down(k) return wml.key_down(k) and 1 or 0 end
    local f = down(held.W) - down(held.S)
    local r = down(held.D) - down(held.A)
    local u = down(held.E) - down(held.Q)
    x = x + (forward[1] * f + right[1] * r) * step
    y = y + (forward[2] * f + up[2] * u) * step
    z = z + (forward[3] * f + right[3] * r) * step
  end

  bx, by, bz = forward[1], forward[2], forward[3]
  ux, uy, uz = up[1], up[2], up[3]
  rx, ry, rz = right[1], right[2], right[3]

  -- +56 as well as +44: the follow camera writes +56 every frame and the
  -- camera manager would otherwise walk +44 back towards the player.
  write_vec(POS, x, y, z)
  write_vec(LOOK_POS, x, y, z)
  write_vec(RIGHT, right[1], right[2], right[3])
  write_vec(UP, up[1], up[2], up[3])
  write_vec(FORWARD, forward[1], forward[2], forward[3])
end

-- Both camera functions are cut and both drive the update. The follow camera
-- (0x8210D518) is what aims at the player and resolves camera collision against
-- them every frame, so it has to be cut or the camera slides with the player;
-- the manager (0x82109608) places the camera, so it has to be cut too or it
-- overwrites what we just wrote. The port's Studio camera cuts the follow one
-- (kbm.cpp:812-818) and writes the same five slots.
local function own_camera(ctx)
  if updated_this_frame then return end
  updated_this_frame = true
  update_camera()
end

wml.hook(FOLLOW_CAMERA, function(ctx)
  if state == OFF then
    ctx:call_original()
    return
  end
  own_camera(ctx)
end)

wml.hook(CAMERA_UPDATE, function(ctx)
  if state == OFF then
    ctx:call_original()
    return
  end
  own_camera(ctx)
end)

-- Freeze and thaw the world. Everything the port does here that Lua can reach
-- is guest memory, so these are its writes. They have to be repeated every
-- frame: the game rewrites all three as it runs, so a one-shot freeze lasts a
-- frame, which is the same trap the HUD byte sets.
local function freeze()
  saved.divisor = wml.read_f32(TIME_DIVISOR)
  saved.step    = wml.read_u8(FIXED_STEP)
  saved.rate    = wml.read_f32(FIXED_RATE)
  saved.clk_a   = wml.read_u32(CUTSCENE_CLK_A)
  saved.clk_b   = wml.read_u32(CUTSCENE_CLK_B)
  frozen = true
end

local function thaw()
  frozen = false
  wml.write_f32(TIME_DIVISOR, saved.divisor)
  wml.write_u8(FIXED_STEP, saved.step)
  wml.write_f32(FIXED_RATE, saved.rate)
end

local function hold_freeze()
  wml.write_f32(TIME_DIVISOR, FROZEN_DIVISOR)
  wml.write_u8(FIXED_STEP, 1)
  wml.write_f32(FIXED_RATE, FROZEN_RATE)
  wml.write_u32(CUTSCENE_CLK_A, saved.clk_a)
  wml.write_u32(CUTSCENE_CLK_B, saved.clk_b)
end

-- Built from the settings rather than written out literally, so changing `key`
-- in mod.ini cannot leave the overlay advertising the wrong one.
local function help_text()
  -- Names, not the resolved VKs: after vk_of() these may be numbers, and
  -- "20   lock the camera" tells the reader nothing.
  local key_name = tostring(fly_key)
  local pause_name = tostring(pause_key)
  return table.concat({
    state == LOCKED and "FREE CAMERA  [LOCKED]" or "FREE CAMERA",
    key_name .. "       " .. (state == LOCKED and "switch the free camera off"
                                             or "lock the camera in place"),
    "",
    "WASD          fly forward / back / left / right",
    "Q E           down / up",
    "SHIFT         fly faster",
    "CONTROL       fly slower",
    "mouse         look around",
    "wheel         change the fly speed",
    "",
    pause_name .. "       freeze the world (the camera stays free)",
    tostring(help_key) .. "       show or hide this list",
  }, "\n")
end

-- Drawing has to be native. wml.overlay_text is an OPTIONAL tail extension of
-- WmlApi that the loader does not expose to Lua at all: the Lua table has no
-- drawing call, so calling it raises "attempt to call a nil value". That is why
-- the Speedometer is a DLL. So this half only writes the text to help.txt and
-- the FreeCamHelp.dll next to it displays the file. This half stays the single
-- source of truth for whether the camera is on, so the two cannot disagree.
local function set_help(on)
  local f = io.open(wml.mod_folder .. "/help.txt", "w")
  if not f then return end
  if on and show_help then f:write(help_text(), "\n") end
  f:close()
end

wml.on_frame(function()
  -- Cleared before either camera function runs, so whichever of them gets
  -- there first does the work and the other stands down.
  updated_this_frame = false

  if pressed(help_key) then
    show_help = not show_help
    set_help(show_help)
    wml.log("Free Camera: control text " .. (show_help and "shown" or "hidden"))
  end

  if pressed(fly_key) then
    -- Off -> fly freely -> locked in place -> off.
    state = (state + 1) % 3
    seeded = false
    -- Turning the camera off must never leave the world frozen. With the camera
    -- handed back to the player there would be no way to undo it.
    if state == OFF and frozen then thaw() end
    set_help(state ~= OFF and show_help)
    if state == OFF then
      wml.log("Free Camera off")
    elseif state == FREE then
      wml.log("Free Camera on - WASD to fly, Q/E down up, mouse to look, " ..
              "press " .. fly_key .. " again to lock it in place")
    else
      wml.log("Free Camera locked in place - press " .. fly_key ..
              " again to switch it off")
    end
  end

  -- Freeze is only offered while the free camera is on. A frozen world with the
  -- camera already handed back is a game you cannot move in, and the key that
  -- would thaw it is the one you just pressed to leave.
  if state ~= OFF and pressed(pause_key) then
    if frozen then thaw() else freeze() end
    wml.log("Free Camera: world " .. (frozen and "frozen" or "running"))
  end

  if frozen then hold_freeze() end

  -- Keys go only while the camera is really flying, so the character keeps WASD
  -- whenever right mouse is up. Changed-state-only, because take_key is a
  -- loader call and there is no reason to make it every frame.
  -- The movement keys are taken from the game only while the camera can
  -- actually be moved, so the player walks normally the moment it is locked or
  -- off. Right mouse is not the modifier any more: the state is the modifier.
  local want = state == FREE
  if want ~= keys_taken then
    keys_taken = want
    take_fly_keys(want)
  end
end)

-- Clear any help.txt left behind by a previous run. The DLL displays whatever
-- that file says, so a stale one from a crash or a kill while the camera was on
-- would put the controls on screen with the camera off, and nothing would take
-- them down until the key was pressed.
set_help(false)

wml.log("Free Camera: press " .. fly_key .. " to toggle the free camera")