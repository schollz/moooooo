# moooooo

A MIDI looper for the monome norns.


## Requirements

## Documentation

- E1 selects loop
- K2/K3 selects loop
- K1+E2: change MIDI in device
- K1+E3: change MIDI out device
- K1+K2: toggle recording
- K1+E3: toggle playback
- hold K1+K2: erase
- hold K1+E3: quantize

## Usage

- 


## Development

For formatting: 

```
lua-format -i --indent-width=2 --column-limit=120 --no-keep-simple-function-one-line --no-spaces-around-equals-in-field --no-spaces-inside-table-braces --no-spaces-inside-functiondef-parens lib/looper.lua && lua-format -i --indent-width=2 --column-limit=120 --no-keep-simple-function-one-line --no-spaces-around-equals-in-field --no-spaces-inside-table-braces --no-spaces-inside-functiondef-parens moooooo.lua 
```
