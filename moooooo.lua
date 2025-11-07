-- moooooo v0.1.0
--
--
-- llllllll.co/t/moooooo
--
--
--
--    ▼ instructions below ▼
--
-- E1 selects loop
-- K2/K3 selects loop
-- E2
-- E3 
-- K1+K2: toggle recording
-- K1+E3: toggle playback
-- hold K1+K2: erase 
-- hold K1+E3: quantize
-- 
looper_ = include("lib/looper")

global_shift = false
global_num_loops = 6
global_loops = {}

function init()
    print("midilooper init")

    local midi_names = {}
    local midi_device = {}
    for i = 1, #midi.vports do
        if midi.vports[i] ~= nil and midi.vports[i].name ~= nil and midi.vports[i].name ~= "" then
            local name = midi.vports[i].name
            -- trim whitespace from the name
            name = name:gsub("^%s*(.-)%s*$", "%1")
            if name ~= "none" then
                table.insert(midi_names, name)
                table.insert(midi_device, midi.connect(i))
                print("added midi device: " .. name)
            end
        end
    end
    table.insert(midi_names, "none")

    -- global parameters
    params:add_number("selected_loop", "Selected Loop", 1, global_num_loops, 1)
    params:add_option("looper_midi_in_device", "MIDI In", midi_names, 1)
    params:add_number("looper_midi_in_channel", "MIDI In Channel", 1, 16, 1)
    -- midi augmentation 
    params:add_group("MIDI Out Augmentation", 16)
    for i = 1, 16 do
        params:add_number("midi_ch_augment_" .. i, "Ch " .. i .. " augment", -64, 64, 0)
    end

    for i = 1, global_num_loops do
        global_loops[i] = looper_:new({
            id = i,
            midi_names = midi_names,
            midi_device = midi_device
        })
    end
    params:default()
    params:bang()

    -- connect to all midi devices
    for i, md in ipairs(midi_device) do
        print("Connecting to MIDI device: " .. i .. " " .. midi_names[i])
        md.event = function(data)
            local d = midi.to_msg(data)
            if d.type == "clock" then
                return
            end
            print(i .. " " .. midi_names[i] .. " type", d.type, "ch", d.ch, "indevice",
                params:get("looper_midi_in_device"), "in channel", params:get("looper_midi_in_channel"))
            if i ~= params:get("looper_midi_in_device") then
                do
                    return
                end
            end
            if d.ch ~= params:get("looper_midi_in_channel") then
                do
                    return
                end
            end
            if d.type == "note_on" then
                print("note_on", d.note, d.vel)
                global_loops[params:get("selected_loop")]:record_note_on(d.ch, d.note, d.vel)
            elseif d.type == "note_off" then
                global_loops[params:get("selected_loop")]:record_note_off(d.ch, d.note)
            end
        end
    end

    clock.run(function()
        while true do
            redraw()
            clock.sleep(1 / 60)
        end
    end)

    clock.run(function()
        while true do
            clock.sync(1 / 32)
            for i = 1, global_num_loops do
                global_loops[i]:emit()
            end
        end
    end)

    -- go through each device
    for i = 1, #midi_device do
        clock.run(function()
            for ch = 1, 4 do
                for note = 1, 127 do
                    -- send a note off to each device
                    midi_device[i]:note_off(note, 0, ch)
                    clock.sleep(0.01) -- small delay to ensure all notes are sent
                end
            end
            print("Closed all notes on device " .. midi_device[i].name)
        end)
    end
end

function key(k, v)
    if k == 1 then
        global_shift = v == 1
    else
        global_loops[params:get("selected_loop")]:key(k, v, global_shift)
    end
end

function enc(k, d)
    if global_shift then
        if k == 1 then
            global_loops[params:get("selected_loop")]:enc(k, d)
        elseif k == 2 then
            -- change input device
            params:delta("looper_midi_in_device", d)
        elseif k == 3 then
            -- change output device
            params:delta("looper_" .. params:get("selected_loop") .. "_midi_device", d)
        end
    elseif k==1 then 
        params:delta("selected_loop", d)
    else
        global_loops[params:get("selected_loop")]:enc(k, d)
    end
end

function redraw()
    screen.clear()

    screen.level(global_shift and 15 or 3)
    screen.move(128, 6)
    -- screen.text_right(params:string("looper_midi_in_device") .. " ch" ..
    --                       params:string("looper_midi_in_channel"))

    global_loops[params:get("selected_loop")]:redraw(global_shift)

    screen.update()
end
