-- Copyright (c) 2020, petzku <petzku@zku.fi>
-- Copyright (c) 2020, The0x539 <the0x539@gmail.com>
--
-- Permission to use, copy, modify, and distribute this software for any
-- purpose with or without fee is hereby granted, provided that the above
-- copyright notice and this permission notice appear in all copies.
--
-- THE SOFTWARE IS PROVIDED 'AS IS' AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
-- ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
-- WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
-- ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
-- OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

local tr = aegisub.gettext

script_name = tr'Encode Clip'
script_description = tr'Encode various clips from the current selection'
script_author = 'petzku'
script_namespace = "petzku.EncodeClip"
script_version = '0.5.2'


local haveDepCtrl, DependencyControl, depctrl = pcall(require, "l0.DependencyControl")
if haveDepCtrl then
    depctrl = DependencyControl{feed = "https://raw.githubusercontent.com/petzku/Aegisub-Scripts/stable/DependencyControl.json"}
end

-- "\" on windows, "/" on any other system
local pathsep = package.config:sub(1,1)
local is_windows = pathsep == "\\"

-- find the best AAC encoder available to us, since ffmpeg-internal is Bad
-- mpv *should* support --oac="aac_at,aac_mf,libfdk_aac,aac", but it doesn't so we do this
local aac_encoder = nil
local function best_aac_encoder()
    if aac_encoder ~= nil then
        return aac_encoder
    end
    local priorities = {aac = 0, libfdk_aac = 1, aac_mf = 2, aac_at = 3}
    local best = "aac"
    for line in run_cmd("mpv --oac=help", true):gmatch("[^\r\n]+") do
        local enc = line:match("--oac=(%S*aac%S*)")
        if enc and priorities[enc] and priorities[enc] > priorities[best] then
            best = enc
        end
    end
    aac_encoder = best
    return best
end

local function calc_start_end(subs, sel)
    local t1, t2 = math.huge, 0
    for _, i in ipairs(sel) do
        t1 = math.min(t1, subs[i].start_time)
        t2 = math.max(t2, subs[i].end_time)
    end
    return t1/1000, t2/1000
end

function make_clip(subs, sel, hardsub, audio)
    if audio == nil then audio = true end --encode with audio by default

    local t1, t2 = calc_start_end(subs, sel)

    local props = aegisub.project_properties()
    local vidfile = props.video_file
    local subfile = aegisub.decode_path("?script") .. pathsep .. aegisub.file_name()

    local outfile
    if aegisub.decode_path("?script") == "?script" then
        -- no script file to work with, save next to source video instead
        outfile = vidfile
        hardsub = false
    else
        outfile = subfile
    end
    outfile = outfile:gsub('%.[^.]+$', '') .. ('_%.3f-%.3f'):format(t1, t2) .. '%s.mp4'

    local postfix = ""

    local audio_opts
    if audio then
        audio_opts = table.concat({
            '--oac=' .. best_aac_encoder(),
            '--oacopts="b=256k,frame_size=1024"'
        }, ' ')
    else
        audio_opts = '--audio=no'
        postfix = postfix .. "_noaudio"
    end

    local sub_opts
    if hardsub then
        sub_opts = table.concat({
            '--sub-font-provider=auto',
            '--sub-file="%s"'
        }, ' '):format(subfile)
    else
        sub_opts = '--sid=no'
        postfix = postfix .. "_nosub"
    end

    -- TODO: allow arbitrary command line parameters from user
    local commands = {
        'mpv', -- TODO: let user specify mpv location if not on PATH
        '--start=%.3f',
        '--end=%.3f',
        '"%s"',
        '--vf=format=yuv420p',
        '--o="%s"',
        '--ovcopts="profile=main,level=4.1,crf=23"',
        audio_opts,
        sub_opts
    }

    outfile = outfile:format(postfix)
    local cmd = table.concat(commands, ' '):format(t1, t2, vidfile, outfile)
    run_cmd(cmd)
end

function make_audio_clip(subs, sel)
    local t1, t2 = calc_start_end(subs, sel)

    local props = aegisub.project_properties()
    local vidfile = props.video_file

    local outfile
    if aegisub.decode_path("?script") == "?script" then
        outfile = vidfile
    else
        outfile = aegisub.decode_path("?script") .. pathsep .. aegisub.file_name()
    end
    outfile = outfile:gsub('%.[^.]+$', '') .. ('_%.3f-%.3f'):format(t1, t2) .. '.aac'

    local commands = {
        'mpv',
        '--start=%.3f',
        '--end=%.3f',
        '"%s"',
        '--video=no',
        '--o="%s"',
        '--oac=' .. best_aac_encoder(),
        '--oacopts="b=256k,frame_size=1024"'
    }

    local cmd = table.concat(commands, ' '):format(t1, t2, vidfile, outfile)
    run_cmd(cmd)
end

function run_cmd(cmd, quiet)
    if not quiet then
        aegisub.log('running: ' .. cmd .. '\n')
    end

    local output
    if is_windows then
        -- command lines over 256 bytes don't get run correctly, make a temporary file as a workaround
        local tmp = aegisub.decode_path('?temp' .. pathsep .. 'tmp.bat')
        local f = io.open(tmp, 'w')
        f:write(cmd)
        f:close()

        local p = io.popen(tmp)
        output = p:read('*a')
        if not quiet then
            aegisub.log(output)
        end
        p:close()

        os.execute('del ' .. tmp)
    else
        -- on linux, we should be fine to just execute the command directly
        local p = io.popen(cmd)
        output = p:read('*a')
        if not quiet then
            aegisub.log(output)
        end
        p:close()
    end
    return output
end

function show_dialog(subs, sel)
    local VIDEO = tr"&Video clip"
    local AUDIO = tr"Audio-&only clip"
    local diag = {
        {class = 'label', x=0, y=0, label = tr"Settings for video clip: "},
        {class = 'checkbox', x=1, y=0, label = tr"&Subs", hint = tr"Enable subtitles in output", name = 'subs', value = true},
        {class = 'checkbox', x=2, y=0, label = tr"&Audio", hint = tr"Enable audio in output", name = 'audio', value = true}
    }
    local buttons = {AUDIO, VIDEO, tr"&Cancel"}
    local btn, values = aegisub.dialog.display(diag, buttons)

    if btn == AUDIO then
        make_audio_clip(subs, sel)
    elseif btn == VIDEO then
        make_clip(subs, sel, values['subs'], values['audio'])
    end
end

function make_hardsub_clip(subs, sel, _)
    make_clip(subs, sel, true, true)
end

function make_raw_clip(subs, sel, _)
    make_clip(subs, sel, false, true)
end

function make_hardsub_clip_muted(subs, sel, _)
    make_clip(subs, sel, true, false)
end

function make_raw_clip_muted(subs, sel, _)
    make_clip(subs, sel, false, false)
end

local macros = {
    {tr'Clip with subtitles',   tr'Encode a hardsubbed clip encompassing the current selection', make_hardsub_clip},
    {tr'Clip raw video',        tr'Encode a clip encompassing the current selection, but without subtitles', make_raw_clip},
    {tr'Clip with subtitles (no audio)',tr'Encode a hardsubbed clip encompassing the current selection, but without audio', make_hardsub_clip_muted},
    {tr'Clip raw video (no audio)',     tr'Encode a clip encompassing the current selection of the video only', make_raw_clip_muted},
    {tr'Clip audio only',       tr'Clip just the audio for the selection', make_audio_clip},
    {tr'Clipping GUI',          tr'GUI for all your video/audio clipping needs', show_dialog}
}
if haveDepCtrl then
    depctrl:registerMacros(macros)
else
    for i,macro in ipairs(macros) do
        local name, desc, fun = unpack(macro)
        aegisub.register_macro(script_name .. '/' .. name, desc, fun)
    end
end
