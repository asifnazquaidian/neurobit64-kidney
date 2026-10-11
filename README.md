# NeuroBit64-Kidney: a 1000-nephron network chip: 1000 nephron units, each with an alpha-1 and a beta-1 adrenergic neuron

A variant of [NeuroBit64](https://github.com/asifnazquaidian/neurobit64) for the kidney. **Design and simulation only: no chip has been fabricated and there is no mask layout (GDSII) for this chip.**

It belongs to a family of three organ chips that share one architecture, one brain link and one telemetry format:
[NeuroBit64-Cardio](https://github.com/asifnazquaidian/neurobit64-cardio), [NeuroBit64-Pancreas](https://github.com/asifnazquaidian/neurobit64-pancreas), [NeuroBit64-Kidney](https://github.com/asifnazquaidian/neurobit64-kidney).

| Item | Value |
|---|---|
| Network | 1000 nephron units + 1000 alpha-1 adrenergic neurons (vasoconstriction) + 1000 beta-1 adrenergic neurons (renin release) |
| Architecture | one cell circuit shared by all units, one unit per slot of 8 clocks (as in NeuroBit64-S), 1000 slots per tick |
| Clock | 8 MHz gives 1 tick = 1 ms, i.e. the model runs in real time |
| State | `{n2[6:0], n1[6:0], act, tr[11:0], u[15:0], v[11:0]}` = 55 bits per unit, held in a circulating shift register |
| Brain link | 3 wires to a NeuroBit64-S chip: `nb_sdi` (32 group-activity bytes and their inverted copies, one sample per neuron), `nb_sdo` and `nb_sync` (its 64 decision bits; neurons 0-31 are counted as sympathetic, 32-63 as parasympathetic drive) |
| Telemetry | UART, 115.9 kbaud, one 19-byte frame every 16 ms, for a Bluetooth serial module or a USB cable; and the bit stream of a Bluetooth LE advertising packet every 128 ms for a 2.4 GHz transmitter |
| Raster output | `sdo`, `sck`, `sync`: one event bit per unit per tick in the NeuroBit64-S serial format (1 Mbit/s at 8 MHz) |
| Size (SkyWater 130 nm, Yosys) | about 211,392 standard cells, 51,870 flip-flops, 1.92 mm2 of cell area (synthesised); die about 2.2 x 2.2 mm with 24 pads |

```
                 nb_sdi                       uart_tx  --> Bluetooth serial module --> phone / PC
 NeuroBit64-S  <--------  NeuroBit64-Kidney    bb_data  --> 2.4 GHz GFSK transmitter (not designed)
 (brain chip)  -------->  1000 units            sdo/sck/sync --> serial memory (raster)
              nb_sdo, nb_sync
```

## The model

- Cell: the HEC model of the thesis (chapter 3, regular-spiking constants C = 100, k = 0.7, a = 0.03, b = -2, c = -50, d = 100) with its adaptive threshold. One spike stands for one quantum of filtrate of a nephron; the threshold elevation after each spike (+40 mV, decay 128 ms) plays the part of tubuloglomerular feedback.
- Drive of a nephron = perfusion pressure x 10/64 + renin field / 128, minus 3 mV for every spike of its alpha-1 neuron.
- Renin field: every tick it changes by (16 - filtration spikes of all nephrons), so it rises while total filtration is below the set point and makes the working nephrons filter more. A second, decaying part is added by the spikes of the beta-1 neurons. When nephrons are lost, the remaining ones are driven harder (hyperfiltration) and total filtration stays normal until the field reaches its limit.
- Neurons: the alpha-1 neuron integrates the sympathetic signal, the beta-1 neuron the sympathetic signal plus a low-pressure term (NeuroBit64 leaky integrate-and-fire rule).

### What was added to the thesis model

- The thesis contains no kidney model. Everything here except the HEC equations and constants is an extension proposed in the revised thesis chapter "Conclusion and Future Directions": the meaning of a spike, the feedback, the renin field, the neurons and the eight conditions. None of it has been compared with kidney recordings or clinical data.

## What the chip reports

Every 16 ticks: sequence number, organ and condition, flags, mean membrane potential, filtration spikes, alpha-1 spikes, beta-1 spikes, working nephrons in the last 256 ms, total filtration in % of the set point, perfusion pressure, renin level, brain drive.

Flags: nephrons missing (< 875 working), hyperfiltration (filtration per working nephron > 125 %), low total filtration (< 60 %), renin high, strong sympathetic drive, high perfusion pressure (> 140 mmHg), early-loss pattern (nephrons missing and hyperfiltration while total filtration is still normal).

Conditions (pins `cond[2:0]`, for demonstration and test): 0 healthy, 1-3 loss of 25 %, 50 %, 75 % of the nephrons, 4 perfusion pressure 60 mmHg, 5 160 mmHg, 6 high sympathetic tone, 7 pressure sweep 60-187 mmHg.

Input: the perfusion pressure can be written through `uart_rx` (bytes `50 lo hi`, mmHg); `50 FF FF` returns to the built-in value.

Results of the software model (`design/results/model_summary.txt`):

```
NeuroBit64-Kidney, software model

A. All conditions, 16.4 s of model time (values of the last 256-tick epoch; flags over the last 12 s)

cond  condition                            brain chip  working  filtration %  per nephron Hz  renin %  flags raised (% of reports)
0     healthy kidney                       none           1000          100            16.1       13  none
1     early nephron loss (25 %)            none            750          100            21.3       22  nephrons missing 100, hyperfiltration 100, early-loss pattern 100
2     moderate nephron loss (50 %)         none            500           99            31.9       50  nephrons missing 100, hyperfiltration 100, renin high 20, early-loss pattern 100
3     advanced nephron loss (75 %)         none            250           55            35.2      100  nephrons missing 100, hyperfiltration 100, low total filtration 100, renin high 100
4     low perfusion pressure (60 mmHg)     none           1000           99              16       28  none
5     high perfusion pressure (160 mmHg)   none           1000          159            25.5        0  hyperfiltration 100, high perfusion pressure 100
6     high sympathetic tone                none           1000          100              16      100  renin high 100, strong sympathetic drive 100
7     healthy kidney, pressure sweep       none           1000           95            15.3       29  hyperfiltration 52, high perfusion pressure 49
0     healthy kidney                       connected      1000          100            16.1       13  none
1     early nephron loss (25 %)            connected       750          100            21.3       22  nephrons missing 100, hyperfiltration 100, early-loss pattern 100
2     moderate nephron loss (50 %)         connected       500           99            31.9       50  nephrons missing 100, hyperfiltration 100, renin high 20, early-loss pattern 100
3     advanced nephron loss (75 %)         connected       250           55            35.2      100  nephrons missing 100, hyperfiltration 100, low total filtration 100, renin high 100
4     low perfusion pressure (60 mmHg)     connected      1000           99              16       98  renin high 100
5     high perfusion pressure (160 mmHg)   connected      1000          159            25.5        0  hyperfiltration 100, high perfusion pressure 100
6     high sympathetic tone                connected      1000           99              16      100  renin high 100, strong sympathetic drive 100
7     healthy kidney, pressure sweep       connected      1000           95            15.3       92  hyperfiltration 52, renin high 5, high perfusion pressure 49

B. Healthy kidney at fixed perfusion pressure (8.2 s each)

pressure mmHg  filtration %  per nephron Hz  renin %
       50           100            16.1       37
       60           100              16       35
       70            99              16       32
       80            99              16       17
       90           100              16       15
      100           100              16       15
      110           100              16        1
      120           100            16.1        0
      140           124            19.9        0
      160           159            25.5        0
      180           183            29.3        0
      200           205            32.8        0
```

## Verification

The Verilog was simulated with Icarus Verilog and compared with the software model `design/model/nb64_kidney_model.js`, which uses the same integer arithmetic. Compared: every UART frame, every Bluetooth LE advertising packet bit by bit, the number of events and a 64-bit signature of the whole raster stream and, with a NeuroBit64-S chip (its real Verilog) wired to the link, the word count and signature of that chip. An independent receiver model also checked the CRC of every advertising packet.

| Condition | Ticks (ms) | NeuroBit64-S connected | Frames | BLE packets | Raster events | Brain words | Result |
|---|---|---|---|---|---|---|---|
| 0 | 1280 | yes | 80 | 30 | 20224 | 19998 | identical |
| 1 | 960 | no | 60 | 21 | 14429 | - | identical |
| 2 (input 70 written through uart_rx in tick 40) | 640 | no | 40 | 15 | 7627 | - | identical |
| 3 | 960 | yes | 60 | 21 | 8049 | 14998 | identical |
| 6 | 640 | yes | 40 | 15 | 7527 | 9998 | identical |
| 7 | 960 | no | 60 | 21 | 14167 | - | identical |
| 5 | 480 | no | 30 | 9 | 12140 | - | identical |

Full record: `design/results/verilog_vs_model.txt`. Icarus Verilog needs about 0.25 s per tick for 1000 units, so the long runs (60 s of model time) were made with the software model only.

## Size

| Units | Standard cells | Flip-flops | Cell area (um2) | |
|---|---|---|---|---|
| 64 | 20122 | 4132 | 179627 | synthesised |
| 128 | 33121 | 7396 | 297924 | synthesised |
| 1000 | 211392 | 51870 | 1917487 | synthesised (straight-line estimate from the two rows above: 210232 cells, 1909724 um2) |

About 1848 um2 per unit and 61330 um2 for everything else. `design/floorplan.svg` is a to-scale block floorplan (a planning drawing). The chip is larger than the biggest Tiny Tapeout tile (8x2 tiles, about 0.3 mm2), so it needs its own die on an open multi-project wafer run.

## What has NOT been done

- **No layout.** Place and route, timing analysis and gate-level simulation have not been run. 8 MHz is slow for 130 nm, but that is an expectation, not a result.
- **No radio.** The chip makes the bits of the advertising packet; the 2.4 GHz transmitter is analog and is not designed. The practical route to a phone is the UART pin with a ready-made Bluetooth serial module, and that path has not been tried with hardware.
- **The link was simulated only with both chips released from reset together.** The logic that re-aligns to the `sync` pin of NeuroBit64-S after a different start has not been exercised.
- **The meaning of the brain link is a convention of these chips** (which NeuroBit64 neurons count as sympathetic or parasympathetic). NeuroBit64-S is a general 64-neuron chip, not a model of a brain region.
- "Early-loss pattern" is a property of this model (compensation hides the loss in the total filtration). Whether such a pattern can be measured in a real kidney is an open research question.

## Files

| Path | Content |
|---|---|
| `design/rtl/nb64_kidney.v` | the chip |
| `design/rtl/nb64_link.v`, `design/rtl/nb64_telemetry.v` | brain link, UART and Bluetooth LE packet generator (shared by the three chips) |
| `design/tb/` | test bench and the NeuroBit64-S chip used in the link tests |
| `design/model/` | software model (`nb64_kidney_model.js`, `nb64_common.js`), test and summary scripts |
| `design/results/` | test records, model summary, synthesis reports |
| `design/synth/` | Yosys scripts |
| `app/` | NeuroBit64 Organ Monitor (web app) |

## Repeat the tests

Needs Node.js, Icarus Verilog and (for the size) Yosys with the sky130 liberty file.

```
pwsh design/run_tests.ps1 -Organ kidney -Tests "0,320,0;1,320,1"     # condition,ticks,link ; ...
node design/model/summary.js
```

## Monitor app

Open `app/index.html` (or publish the `app` folder as a static site). It runs the chip model in the browser, or receives the frames from a Bluetooth serial module (Web Bluetooth) or a serial port (Web Serial) and shows the readings, the flags and the signals. It was tested with the simulated source only.

## Reference and licence

A. Mehmood, "Artificial Neuron Model for Large Scale Spiking Brain Neural Network", PhD thesis, University of Engineering and Technology Taxila, 2025.

Copyright (c) 2026 Asif Mehmood. Apache License 2.0 (see `LICENSE`). AI tools were used where applicable, for convenience, in preparing the circuit description, the tests and this document. This is a research design, not a medical device.
