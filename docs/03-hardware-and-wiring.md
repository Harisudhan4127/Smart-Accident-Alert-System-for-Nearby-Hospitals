# 03 — Hardware and wiring

Everything in this document is derived from `firmware/SmartAccidentAlert/config.h`,
which is the single source of truth for the pin map, the electrical assumptions
and the timing constants. Where `firmware/README.md` disagrees with `config.h`,
`config.h` wins and the disagreement is called out at the end.

## Components

| # | Component | Qty | Interface | Notes |
| --- | --- | --- | --- | --- |
| 1 | ESP32 DevKit v1 | 1 | — | 30-pin. Dual core, 4 MB flash, Wi-Fi unused |
| 2 | MPU6050 | 1 | I²C `0x68` | Accel ±4 g, gyro ±500 °/s |
| 3 | SW-420 | 1 | GPIO 27 | Vibration switch. **Active high** |
| 4 | Buzzer | 1 | GPIO 25 | **Active low**, via NPN |
| 5 | SOS button | 1 | GPIO 26 | **Active low**, internal pull-up |
| 6 | Green LED | 1 | GPIO 32 | **Active high** |
| 7 | Red LED | 1 | GPIO 33 | **Active high** |
| 8 | 0.96" SSD1306 OLED | 1 | I²C `0x3C` | Shares the MPU bus |
| 9 | Li-ion + TP4056 | 1 | GPIO 34 (ADC), 35 (CHRG) | 2:1 divider for the sense wire |
| 10 | 220 Ω resistors | 3 | — | LED current limiting |
| 11 | 1 kΩ resistors | 2 | — | SW-420 pull-up, button if the internal one is bypassed |

## Pin map

| Signal | GPIO | Direction | Active level | Notes |
| --- | --- | --- | --- | --- |
| I²C SDA | 21 | bidirectional | — | 400 kHz. Shared with the OLED |
| I²C SCL | 22 | output | — | Shared with the OLED |
| SW-420 OUT | 27 | input | **HIGH** | Module pulls the pin high on vibration |
| Buzzer | 25 | output | **LOW** | Through an NPN transistor; never drive a buzzer directly |
| SOS button | 26 | input | **LOW** | Internal pull-up enabled in software |
| Green LED | 32 | output | **HIGH** | Through 220 Ω |
| Red LED | 33 | output | **HIGH** | Through 220 Ω |
| Battery sense | 34 | input | — | Input-only pin, which is why it is the right choice for an ADC |
| TP4056 CHRG | 35 | input | **LOW** | Open-drain. Optional; `kChargingPinPresent` |

Three of these are active-low and one is active-high, which is exactly the kind
of detail that produces a node that works on the bench and not in a car. They
are compile-time constants in `config.h`:

```cpp
constexpr bool kBuzzerActiveLow  = true;
constexpr bool kLedActiveHigh    = true;   // both LEDs
constexpr bool kSw420ActiveHigh  = true;   // module pulls OUT HIGH on vibration
constexpr bool kSosButtonActiveLow = true;
```

`kChargingPinPresent` and `kChargingHeuristic` both default to `true`. If the
CHRG pin is not wired at all, build with `-DSAAS_CHARGING_PIN_PRESENT=0`... which
is not currently a thing: the constant is `constexpr bool` in the header, not an
`#ifndef` macro, so it is edited in place. That is a small piece of friction
worth knowing about before you respin a board.

## Power

```
  USB 5V ──┬── TP4056 ──┬── Li-ion cell (3.7 V nominal, 4.2 V full)
            │            │
            │            ├── 2:1 divider ── GPIO 34 (ADC1_CH6)
            │            └── CHRG ────────── GPIO 35
            │
            └── VS-3V3 regulator ── ESP32, MPU6050, OLED, SW-420
```

- **Divider:** two equal resistors, so the ADC sees `cell / 2`. A 4.2 V cell
  becomes 2.1 V, inside the ESP32's 3.3 V ADC range with headroom. The divider
  is 100 kΩ-class, not 220 Ω: it has to be high enough that it does not drain
  the cell and low enough that the ADC input impedance does not distort the
  reading.
- **Below 1.2 V on the ADC** (`kBatteryAdcIgnoreMv`) is treated as "no battery
  connected", i.e. USB only. Without that floor, a floating input reads as a
  full cell.
- **A TP4056 is a charge controller, not a power path.** Charging while the
  system draws load is workable for a prototype but is not what the IC was
  designed for. A real deployment wants a proper power-path IC.
- **Peak current:** the buzzer and the ESP32's radio bursts dominate. Budget
  500 mA average, 800 mA peak for a 2000 mAh cell, which is roughly four hours
  at full duty cycle with the radio on. See [07](07-memory-and-power.md) for
  what the firmware does about that, which is currently nothing.

## The BLE service

One custom service, five characteristics. The base UUID is shared; the last four
hex digits identify the characteristic.

| Characteristic | UUID suffix | Direction | Purpose |
| --- | --- | --- | --- |
| SERVICE | `7c9e0000-1e4a-4f6b-9c2d-5a1b7c30d001` | — | The service itself |
| TX | `...0001` | node → phone | Telemetry and events. Notify |
| RX | `...0002` | phone → node | Commands and config. Write |
| CTRL | `...0003` | node → phone | Events, out of band from telemetry. Notify |
| INFO | `...0004` | node → phone | Identity, on connect. Notify |

Splitting CTRL out of TX matters: a 50 Hz telemetry stream and a latency-critical
event on the same characteristic means an event can sit behind up to 20 ms of
telemetry, and a congested telemetry stream can delay an accident report. Events
get their own path.

Connection parameters (`config.h`):

| Parameter | Value | Why |
| --- | --- | --- |
| TX power | +9 dBm | Enough for a vehicle cabin |
| Advertised TX power | +3 dBm | Conservative, so the phone does not start a connection it cannot sustain |
| Connection interval | 15–30 ms | |
| Slave latency | 4 | |
| Supervision timeout | 4000 ms | A dropped link is noticed in 4 s, not 30 |

`kBleAppearance = 0x03` (Generic Sensor) is what shows up in the phone's BLE
device list.

## Assembly notes that are easy to get wrong

1. **I²C pull-ups.** Most MPU6050 and SSD1306 breakout boards carry their own
   4.7 kΩ pull-ups. Two sets in parallel is fine. If you add a third device,
   400 kHz stops being reliable with everything on 2.2 kΩ.
2. **The buzzer needs a transistor.** It is 30+ mA; a GPIO is not. Active-low
   means the transistor is NPN with the emitter to ground and the base driven
   through 1 kΩ.
3. **The SW-420 module is a potentiometer plus a microswitch.** Set the pot to
   roughly the middle before mounting it, or it will trip on every road joint and
   the detector's biggest corroborating signal becomes noise. The firmware
   debounces it for 25 ms and holds an assertion for 250 ms, which helps, but it
   cannot compensate for a badly set pot.
4. **Mount the node rigidly.** The accelerometer measures what the car does, not
   what the road does — but only if it is not bouncing on its own mount. A
   3D-printed or foam-and-tape mount is the difference between a usable baseline
   and a detector that cannot find its baseline.
5. **The MPU6050 needs a 3.3 V rail.** It is not 5 V tolerant. Most breakouts
   carry a regulator, but not all of them.
6. **GND must be common.** Battery, TP4056, regulator, sensors. An I²C bus with
   two grounds and a floating sensor produces the classic "works when you touch
   it" fault.

## Verifying the hardware

`PROJECT_PLAN.md` §24 has the checklist. The order that actually finds problems
fastest:

1. **Power first, sensors second.** Verify the regulator output and the divider
   reading *before* anything is on the I²C bus. A wrong divider makes the
   battery percentage nonsense for the rest of the project.
2. **I²C alone.** Run with `SAAS_ENABLE_OLED=0` and the buzzer disabled. Get a
   clean MPU6050 stream on the serial monitor first. Two devices on one bus fail
   for different reasons than one device on a broken bus.
3. **SW-420 by hand.** Tap the module and watch GPIO 27 on the monitor. If the
   pin does not go high, the pot or the wiring is wrong and nothing downstream
   will tell you.
4. **Then the OLED, then the buzzer, then the button.**
5. **Then BLE.** The firmware advertises as `SAAS-A1B2C3D4`; a phone that cannot
   see it is a 2.4 GHz problem, not a protocol problem.

## Known discrepancies with `firmware/README.md`

`firmware/README.md` is a useful orientation document but contains three claims
that contradict the code. Following the README rather than `config.h` produces
a node with an inverted SW-420 input.

| Claim in `firmware/README.md` | `config.h` | Effect if you follow the README |
| --- | --- | --- |
| SW-420 is active-**low** | `kSw420ActiveHigh = true` | The vibration signal is inverted: silent while shaking, tripping on silence. The 0.15-weight term becomes a liability. |
| LEDs are active-**low** | `kLedActiveHigh = true` | Both status LEDs are inverted |
| Sampling at 200 Hz | `kSensorHz = 50` (20 ms) | Every window length, every debounce and every filter coefficient in the detector is computed for 50 Hz. A 200 Hz build is not a build, it is a different algorithm. |

`platformio.ini` also carries its own warning: it "has not been run end to end"
because PlatformIO was unavailable in the development environment. The verified
path is the Arduino CLI. See [11](11-deployment.md).
