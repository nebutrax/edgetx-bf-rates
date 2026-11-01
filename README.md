# EdgeTX BF Rates

EdgeTX Lua Tools script for black-and-white 128×64 radios (RadioMaster Boxer etc.) flying Betaflight quads over ExpressLRS / Crossfire.

Store rate sets on the radio and load them to the flight controller over MSP-over-CRSF. No Configurator needed.

## Install

Copy the `SCRIPTS` folder to the root of the radio's SD card:

```
/SCRIPTS/TOOLS/BFRates.lua
```

Then open **SYS → Tools → BF Rates**. The quad must be powered, linked with telemetry on, and **disarmed**. Requires Betaflight 4.2 or newer.

When updating, delete any old `BFRates.luac` next to the script so the radio doesn't keep running the previously compiled version.

## Main screen

- 6 slots, each shown as name, rates type and full-stick roll/pitch/yaw in deg/s.
- `*` marks the slot that matches the FC. `~` means the rates match but the throttle settings differ.
- The bottom line shows the FC's current rates and the active rate profile (`rp1`…).
- **ENTER** opens a menu for the selected slot. The menu also shows the slot's throttle settings next to the FC's, for example `Thr .50/.30 S80`.
  - **Apply to FC**: checks the quad is disarmed, writes the slot, saves EEPROM, reads it back to verify. Shows `Loaded: <name>`.
  - **Edit**: name, rates type and values (see below).
  - **Save FC here**: copies the FC's current rates and throttle settings into the slot. Quickest way to fill slots from rates tuned in Configurator.

## What a slot holds

| Item | Betaflight CLI |
|---|---|
| Type | `rates_type` (BF / RACEFLIGHT / KISS / ACTUAL / QUICK) |
| Roll / Pitch / Yaw rc rate, rate, expo | `roll_rc_rate`, `roll_srate`, `roll_expo`, … |
| Thr mid | `thr_mid` |
| Thr expo | `thr_expo` |
| Thr limit | `throttle_limit_type` (OFF / SCALE / CLIP) |
| Thr lim % | `throttle_limit_percent` (25–100) |

Values are shown the way Configurator shows them for the selected rates type. While editing a rate, the top-right corner shows the resulting full-stick deg/s. Changing the type resets the rates to that type's defaults; throttle settings are kept.

The slot is written to the FC's **active** rate profile. Rate limits and any other rate-profile fields on the FC are left unchanged.

## Storage

Slots are saved to `/SCRIPTS/BFRates.cfg` on the SD card when you leave **Edit** with RTN, or after **Save FC here**. The file is created with the defaults the first time the script opens, and an older file without throttle lines is upgraded on open. Plain text, raw CLI values:

```
s1_name=Default
s1_t=3
s1_r=7,67,0
s1_p=7,67,0
s1_y=7,67,0
s1_th=50,0,0,100
```

`sN_t` is the rates type (0 BF, 1 RACEFLIGHT, 2 KISS, 3 ACTUAL, 4 QUICK). Axis lines are `rc_rate,srate,expo`. `sN_th` is `thr_mid,thr_expo,limit_type,limit_percent`.

## Link status

The bottom-right corner shows the link status while the script waits for the quad:

| Shown | Meaning |
|---|---|
| `noCRSF` | No CRSF/ELRS module active on this model |
| `noTLM` | No telemetry from the quad |
| `t3` | Waiting for the reply to attempt 3 |
| `t3b` | Radio output buffer busy |

## License

MIT
