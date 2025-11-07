local Looper = {}

function Looper:new(args)
    local m = setmetatable({}, {
        __index = Looper
    })
    local args = args == nil and {} or args
    for k, v in pairs(args) do
        m[k] = v
    end
    m:init()
    return m
end

function Looper:queue_clean()
    -- remove any notes that have beat_start > total beats
    notes_to_remove = {}
    for note, data in pairs(self.record_queue) do
        if clock.get_beats() - data.beat_start > self.total_beats * 8 then
            notes_to_remove[note] = true
            print("removing note", note, "from record queue, beat_start:", data.beat_start, "current beat:",
                clock.get_beats())
        end
    end
    for note, _ in pairs(notes_to_remove) do
        self.record_queue[note] = nil
    end
end

function Looper:record_note_on(ch, note, velocity)
    if params:get("looper_" .. self.id .. "_recording_enable") == 2 then
        -- add to the record queue
        self.record_queue[note] = {
            ch = ch,
            note = note,
            velocity = velocity,
            beat_start = clock.get_beats()
        }
        self.beat_last_recorded = self.record_queue[note].beat_start
        -- find any notes in the loop that are within 0.25 beats of the current beat:

        local current_beat_mod = self.record_queue[note].beat_start % self.total_beats
        local notes_to_delete = {}
        for i = 1, #self.loop do
            local note_data = self.loop[i]
            local note_start_beat = note_data.beat_start % self.total_beats
            if math.abs(note_start_beat - current_beat_mod) < params:get("looper_" .. self.id .. "_beat_tol") and
                note_data.times_played > 0 then
                -- remove this note from the loop
                table.insert(notes_to_delete, i)
            end
        end
        if #notes_to_delete > 0 then
            local new_loop = {}
            for i = 1, #self.loop do
                if not self:table_contains(notes_to_delete, i) then
                    table.insert(new_loop, self.loop[i])
                end
            end
            self.loop = new_loop
        end
    end
    if params:get("looper_" .. self.id .. "_passthrough") == 2 and params:get("looper_midi_in_device") ~=
        params:get("looper_" .. self.id .. "_midi_device") then
        -- passthrough enabled and midi output device is different from input device
        self:note_on(note, velocity, true)
    end
end

function Looper:record_note_off(ch, note)
    if params:get("looper_" .. self.id .. "_recording_enable") == 2 then
        -- find the note in the record queue and add it to the loop
        if self.record_queue[note] then
            print("recording note off for", note, "at", clock.get_beats())
            table.insert(self.loop, {
                ch = self.record_queue[note].ch,
                note = self.record_queue[note].note,
                velocity = self.record_queue[note].velocity,
                beat_start = self.record_queue[note].beat_start,
                beat_end = clock.get_beats(),
                times_played = 0
            })
            -- remove the note from the record queue
            self.record_queue[note] = nil
        end
    end
    if params:get("looper_" .. self.id .. "_passthrough") == 2 and params:get("looper_midi_in_device") ~=
        params:get("looper_" .. self.id .. "_midi_device") then
        -- passthrough enabled and midi output device is different from input device
        self:note_off(note, true)
    end
end

function Looper:stop_playing_notes()
    -- turn off every note in playing_notes 
    for note, _ in pairs(self.playing_notes) do
        self:note_off(note)
    end
    self.playing_notes = {}
    -- Clear channel tracking
    self.channel_notes = {
        [1] = {},
        [2] = {},
        [3] = {}
    }
    self.next_channel = 1
end

function Looper:clear_loop()
    self:stop_playing_notes()
    self.loop = {}
    self.record_queue = {}
end

function Looper:table_contains(tbl, i)
    for j = 1, #tbl do
        if tbl[j] == i then
            return true
        end
    end
    return false
end

function Looper:note_on(note, velocity, passthrough)
    local out_dev = params:get("looper_" .. self.id .. "_midi_device")
    if out_dev == #self.midi_names then
        return -- no MIDI output selected
    end

    local ch = params:get("looper_" .. self.id .. "_midi_channel_out")

    -- Passthrough = always echo immediately
    if passthrough then
        -- Use passthrough note_on exactly as recorded, no playback filtering
        if ch < 17 then
            local augmented = note + params:get("midi_ch_augment_" .. ch)
            self.midi_device[out_dev]:note_on(augmented, velocity, ch)
        else
            local assigned = self:assign_channel_for_note(note)
            local augmented = note + params:get("midi_ch_augment_" .. assigned)
            self.midi_device[out_dev]:note_on(augmented, velocity, assigned)
        end
        return
    end

    -- Looper playback path (NOT passthrough)
    if params:get("looper_" .. self.id .. "_playback_enable") ~= 2 then
        return
    end

    if ch < 17 then
        local augmented = note + params:get("midi_ch_augment_" .. ch)
        self.midi_device[out_dev]:note_on(augmented, velocity, ch)
    else
        local assigned = self:assign_channel_for_note(note)
        local augmented = note + params:get("midi_ch_augment_" .. assigned)
        self.midi_device[out_dev]:note_on(augmented, velocity, assigned)
    end

    -- Track only playback notes
    self.playing_notes[note] = true
end

function Looper:note_off(note, passthrough)
    local out_dev = params:get("looper_" .. self.id .. "_midi_device")
    if out_dev == #self.midi_names then
        return -- no MIDI output selected
    end

    local ch = params:get("looper_" .. self.id .. "_midi_channel_out")

    -- Passthrough = echo hardware note_off immediately
    if passthrough then
        if ch < 17 then
            local augmented = note + params:get("midi_ch_augment_" .. ch)
            self.midi_device[out_dev]:note_off(augmented, 0, ch)
        else
            local assigned = self:find_channel_for_note(note)
            if assigned then
                local augmented = note + params:get("midi_ch_augment_" .. assigned)
                self.midi_device[out_dev]:note_off(augmented, 0, assigned)
                self:remove_note_from_channel(note, assigned)
            end
        end
        return
    end

    -- Looper playback path (NOT passthrough)
    if params:get("looper_" .. self.id .. "_playback_enable") ~= 2 then
        return
    end

    if ch < 17 then
        local augmented = note + params:get("midi_ch_augment_" .. ch)
        self.midi_device[out_dev]:note_off(augmented, 0, ch)
    else
        local assigned = self:find_channel_for_note(note)
        if assigned then
            local augmented = note + params:get("midi_ch_augment_" .. assigned)
            self.midi_device[out_dev]:note_off(augmented, 0, assigned)
            self:remove_note_from_channel(note, assigned)
        end
    end

    -- Remove from active playback notes
    self.playing_notes[note] = nil
end


function Looper:assign_channel_for_note(note)
    -- Try channels 1, 2, 3 in order
    for ch = 1, 4 do
        if #self.channel_notes[ch] == 0 then
            -- Channel is empty, assign note here
            table.insert(self.channel_notes[ch], note) -- Store original note
            return ch
        end
    end

    -- All channels have notes, use channel 3 for overflow
    table.insert(self.channel_notes[4], note) -- Store original note
    return 4
end

function Looper:find_channel_for_note(note)
    for ch = 1, 16 do
        for i, stored_note in ipairs(self.channel_notes[ch]) do
            if stored_note == note then
                return ch
            end
        end
    end
    return nil
end

function Looper:remove_note_from_channel(note, channel)
    for i, stored_note in ipairs(self.channel_notes[channel]) do
        if stored_note == note then
            table.remove(self.channel_notes[channel], i)
            break
        end
    end
end

function Looper:beat_in_range(beat, beat_before, beat_after, total_beats)
    if beat_after < beat_before then
        return (beat >= beat_before and beat <= total_beats) or (beat >= 0 and beat <= beat_after)
    else
        return beat >= beat_before and beat <= beat_after
    end
end

function Looper:emit()
    self.beat_current = clock.get_beats()
    local beat_after = self.beat_current % self.total_beats
    local beat_before = self.beat_last % self.total_beats
    local notes_to_erase = {}
    for i = 1, #self.loop do
        local note_data = self.loop[i]
        local note_start_beat = note_data.beat_start % self.total_beats
        local note_end_beat = note_data.beat_end % self.total_beats
        -- check if a note starting
        if self:beat_in_range(note_start_beat, beat_before, beat_after, self.total_beats) then
            if next(self.record_queue) ~= nil or self.beat_current - self.beat_last_recorded <
                params:get("looper_" .. self.id .. "_beat_tol") / 2 then
                -- erase this  note
                table.insert(notes_to_erase, i)
                print("queuing note to remove: ", note_data.note, "from loop")
            else
                -- print("emit note_on", note_data.ch, note_data.note, note_data.velocity)
                self:note_on(note_data.note, note_data.velocity)
                self.loop[i].times_played = self.loop[i].times_played + 1
            end
        end
        -- check if a note is ending
        if self:beat_in_range(note_end_beat, beat_before, beat_after, self.total_beats) then
            -- print("emit note_off", note_data.ch, note_data.note)
            self:note_off(note_data.note)
        end
    end

    if #notes_to_erase > 0 then
        local new_loop = {}
        for i = 1, #self.loop do
            if not self:table_contains(notes_to_erase, i) then
                table.insert(new_loop, self.loop[i])
            end
        end
        self.loop = new_loop
    end

    if self.erase_start ~= nil then
        if self.beat_current - self.erase_start > 2.0 then
            -- erase the loop
            print("erasing loop")
            self:clear_loop()
            self.erase_start = nil
        end

    end

    self.beat_last = self.beat_current
end

function Looper:init()
    self.loop = {}
    self.currentLoop = nil
    self.total_beats = 16
    self.erase_start = nil
    self.record_queue = {}
    self.beat_current = clock.get_beats()
    self.beat_last = clock.get_beats()
    self.beat_last_recorded = clock.get_beats()
    self.playing_notes = {}
    self.do_quantize = false
    self.channel_notes = {}
    for i = 1, 16 do
        self.channel_notes[i] = {}
    end
    self.next_channel = 1 -- for round-robin assignment
    self.key_hold_start = {
        [2] = nil,
        [3] = nil
    }
    self.key_hold_threshold = 2.5 -- 1 second
    self.key_show_threshold = 1.0 -- 2 seconds before showing erase/quantize

    params:add_group("looper_" .. self.id, "Looper " .. self.id, 9)
    -- midi channelt to record on 
    params:add_number("looper_" .. self.id .. "_beats", "Beats", 1, 64, 16)
    params:set_action("looper_" .. self.id .. "_beats", function(value)
        self.total_beats = value * params:get("looper_" .. self.id .. "_bars")
    end)
    params:add_number("looper_" .. self.id .. "_bars", "Bars", 1, 16, 1)
    params:set_action("looper_" .. self.id .. "_bars", function(value)
        self.total_beats = value * params:get("looper_" .. self.id .. "_beats")
    end)
    local usb_midi = 1
    for i, name in ipairs(self.midi_names) do
        local trimmed_name = string.lower((name:gsub("^%s*(.-)%s*$", "%1")))
        print("midi device", i, name, trimmed_name == "usb midi")
        if trimmed_name == "usb midi" then
            usb_midi = i
        end
    end
    params:add_option("looper_" .. self.id .. "_midi_device", "MIDI Out", self.midi_names, usb_midi or #self.midi_names)
    local midi_out_options = {}
    for i = 1, 16 do
        table.insert(midi_out_options, "" .. i)
    end
    table.insert(midi_out_options, "special")
    params:add_option("looper_" .. self.id .. "_midi_channel_out", "MIDI Out Channel", midi_out_options,
        self.id)
    params:add_option("looper_" .. self.id .. "_recording_enable", "Recording", {"Disabled", "Enabled"}, 2)
    params:set_action("looper_" .. self.id .. "_recording_enable", function(value)
        self.record_queue = {}
    end)
    params:add_option("looper_" .. self.id .. "_playback_enable", "Playback", {"Disabled", "Enabled"},2)
    params:add_option("looper_" .. self.id .. "_quantize", "Quantization", {"1/32", "1/16", "1/8", "1/4"}, 1)
    params:add_control("looper_" .. self.id .. "_beat_tol", "Beat tolerance",
        controlspec.new(0.01, 2.0, 'lin', 0.0125, 0.5, 'beats', 0.0125 / (2.0 - 0.01)))
    params:add_option("looper_" .. self.id .. "_passthrough", "Passthrough", {"Disabled", "Enabled"}, 2)

end

function Looper:enc(k, d, shift)
    if shift then 
        if k == 2 then
            -- change midi out device
            params:delta("looper_" .. self.id .. "_midi_device", d)
        end
        if k == 3 then
            -- change midi out channel
            params:delta("looper_" .. self.id .. "_midi_channel_out", d)
        end
    else
        if k == 2 then
            params:delta("looper_" .. self.id .. "_beats", d)
        end
        if k == 3 then
            params:delta("looper_" .. self.id .. "_bars", d)
        end
    end
end

function Looper:key(k, v, shift)
    if k == 2 then
        if v == 1 then
            -- Key pressed - start with toggle, then start timer
            self.key_hold_start[2] = clock.get_beats()
        else
            -- Key released
            if self.key_hold_start[2] then
                local hold_time = clock.get_beats() - self.key_hold_start[2]
                if hold_time < (self.key_show_threshold + self.key_hold_threshold) and hold_time < 1 then
                    params:set("looper_" .. self.id .. "_recording_enable",
                        3 - params:get("looper_" .. self.id .. "_recording_enable"))
                end
            end
            self.key_hold_start[2] = nil
        end
    elseif k == 3 then
        if v == 1 then
            -- Key pressed - start with toggle, then start timer
            self.key_hold_start[3] = clock.get_beats()
        else
            -- Key released
            if self.key_hold_start[3] then
                local hold_time = clock.get_beats() - self.key_hold_start[3]
                print("hold time for key 3:", hold_time)
                if hold_time < (self.key_show_threshold + self.key_hold_threshold) and hold_time < 1 then
                    params:set("looper_" .. self.id .. "_playback_enable",
                        3 - params:get("looper_" .. self.id .. "_playback_enable"))

                end
            end
            self.key_hold_start[3] = nil
        end
    end
end

function Looper:quantize()
    -- Held long enough - quantize
    print("quantizing loop")
    local quantas = {8, 4, 2, 1}
    local quanta = quantas[params:get("looper_" .. self.id .. "_quantize")]
    for i = 1, #self.loop do
        self.loop[i].beat_start = util.round(self.loop[i].beat_start * quanta) / quanta
        self.loop[i].beat_end = util.round(self.loop[i].beat_end * quanta) / quanta
        if self.loop[i].beat_end <= self.loop[i].beat_start then
            self.loop[i].beat_end = self.loop[i].beat_start + 1 / quanta
        end
    end
end

function Looper:note_to_y(note)
    return util.round(util.linlin(16, 90, 64, 10, note))
end

function Looper:redraw(shift)
    local x, y = 0, 0

    screen.move(128, 5)
    screen.level(3)
    screen.text_right(string.format("loop %d, %d/%d", self.id, 1 + math.floor(clock.get_beats() % self.total_beats),
        self.total_beats))

    local x = util.round(128 * (clock.get_beats() % self.total_beats) / self.total_beats)
    -- draw a line for the current beat:
    if (self.total_beats > 1) then
        screen.level(1)
        screen.rect(x, 8, 1, 48)
        screen.fill()
    end

    screen.move(x, 55)
    -- plot recorded beats
    screen.blend_mode(2)
    for i = 1, #self.loop do
        local note_data = self.loop[i]
        local y_pos = self:note_to_y(note_data.note)
        local note_start_beat = note_data.beat_start % self.total_beats
        local note_end_beat = note_data.beat_end % self.total_beats
        local start_x = util.round(128 * note_start_beat / self.total_beats)
        local end_x = util.round(128 * note_end_beat / self.total_beats)
        screen.level(3)
        screen.rect(start_x, y_pos - 2, 3, 3)
        screen.fill()
        screen.rect(end_x, y_pos - 1, 1, 1)
        screen.fill()
        screen.level(1)
        screen.move(start_x, y_pos)
        if end_x > start_x then
            screen.line(end_x, y_pos)
        else
            screen.line(128, y_pos)
            screen.move(0, y_pos)
            screen.line(end_x, y_pos)
        end
        screen.stroke()
    end

    -- top right of screen output the output midi device and channel
    screen.level(shift and 15 or 3)
    screen.move(128, 61)
    local midi_device = params:string("looper_" .. self.id .. "_midi_device")
    local midi_channel = params:string("looper_" .. self.id .. "_midi_channel_out")
    screen.text_right(midi_device .. " ch" .. midi_channel)

    -- plot starts in the queue
    for note, data in pairs(self.record_queue) do
        local note_start_beat = data.beat_start % self.total_beats
        local y_pos = self:note_to_y(note)
        local start_x = util.round(128 * note_start_beat / self.total_beats)
        screen.rect(start_x, y_pos - 2, 3, 3)
        screen.fill()
        -- draw a line for the current beat:
        screen.level(1)
        screen.move(start_x, y_pos)
        if self.beat_current % self.total_beats >= note_start_beat then
            screen.line(util.round(128 * (self.beat_current % self.total_beats) / self.total_beats), y_pos)
        else
            screen.line(128, y_pos)
            screen.move(0, y_pos)
            screen.line(util.round(128 * (self.beat_current % self.total_beats) / self.total_beats), y_pos)
        end
        screen.stroke()
    end
    screen.blend_mode(0)

    -- Shifted view - show normal rec/play unless keys are held long enough
    local show_erase = false
    local show_quantize = false

    -- Check if key 2 has been held long enough to show erase
    if self.key_hold_start[2] then
        local hold_time = clock.get_beats() - self.key_hold_start[2]
        if hold_time >= self.key_show_threshold then
            show_erase = true
            if hold_time >= (self.key_hold_threshold + self.key_show_threshold) then
                -- Held long enough - erase the loop
                print("erasing loop")
                self:clear_loop()
                show_erase = false
            end
        end
    end

    -- Check if key 3 has been held long enough to show quantize
    if self.key_hold_start[3] then
        local hold_time = clock.get_beats() - self.key_hold_start[3]
        if hold_time >= self.key_show_threshold then
            show_quantize = true
            if hold_time >= (self.key_hold_threshold + self.key_show_threshold) then
                -- Held long enough - quantize the loop
                self:quantize()
                show_quantize = false
            end
        end
    end

    x = 3
    y = 60
    if show_erase then
        screen.level(3)
        screen.move(x - 1, y - 10)
        screen.text("erase")

        -- Show erase progress bar (starts filling after show_threshold)
        local hold_time = clock.get_beats() - self.key_hold_start[2]
        local progress_time = hold_time - self.key_show_threshold
        local progress = math.min(progress_time / self.key_hold_threshold, 1.0)
        local bar_width = util.round(28 * progress)
        screen.blend_mode(1)
        screen.rect(x - 3, y - 16, bar_width, 8)
        screen.fill()
        screen.blend_mode(0)
    end
    -- Show normal rec button
    if params:get("looper_" .. self.id .. "_recording_enable") == 2 then
        screen.level(3)
        screen.rect(x - 2, y - 7, 18, 11)
        screen.fill()
        screen.level(0)
    else
        screen.level(3)
    end
    screen.move(x, y)
    screen.text("rec")

    x = 25
    y = 60
    if show_quantize then
        screen.level(3)
        screen.move(x - 1, y - 10)
        screen.text("quantize")

        -- Show quantize progress bar (starts filling after show_threshold)
        local hold_time = clock.get_beats() - self.key_hold_start[3]
        local progress_time = hold_time - self.key_show_threshold
        local progress = math.min(progress_time / self.key_hold_threshold, 1.0)
        local bar_width = util.round(38 * progress)
        screen.blend_mode(1)
        screen.rect(x - 3, y - 16, bar_width, 8)
        screen.fill()
        screen.blend_mode(0)
    end
    if params:get("looper_" .. self.id .. "_playback_enable") == 2 then
        screen.level(3)
        screen.rect(x - 2, y - 7, 21, 11)
        screen.fill()
        screen.level(0)
    else
        screen.level(10)
    end
    screen.move(x, y)
    screen.text("play")

end

return Looper
