# TurtleShell Hub Edition

<p align="center"><img src="../../../../docs/logo.png" width="260" alt="TurtleShell Hub Edition"></p>

Runs **TurtleTAK** and **TurtleMesh** together on the **Hak5 LAN Turtle Hub**, from one payload.

The Hub runs one payload at a time. TurtleShell carries both payloads unchanged, starts them, and keeps them running. For what each one does, see the [TurtleTAK README](https://github.com/SECT0101/TurtleTAK/tree/main/payloads/library/general/TurtleTAK-Hub) and the [TurtleMesh README](https://github.com/SECT0101/TurtleMesh/tree/main/payloads/library/general/TurtleMesh-Hub).

> Use TurtleShell only on networks and radio channels you own or are authorized to use. Meshtastic® is a registered trademark of Meshtastic LLC. Community payload, not supported by Hak5.

## What's inside

| Service | Version | Web console | What it does |
|---|---|---|---|
| **TurtleTAK** | 1.0.1 | `http://<hub>:8484` | The Hub on TAK as a facility sensor: status, GeoChat, network watch alerts, mesh SA bridge, offline map |
| **TurtleMesh** | 1.0.1 | `http://<hub>:8485` | A Meshtastic radio: mesh chat, nodes and map, radio settings, mesh watch and sensor alerts, alerts over LoRa, mesh ↔ TAK bridge |

## How they work together

| | |
|---|---|
| **One TAK setup** | TurtleMesh uses TurtleTAK's TAK Server and certificates (`TAK_FROM_TURTLETAK: 1`, the default). Set up TAK once, in TurtleTAK. |
| **TurtleTAK alerts over LoRa** | New devices, ARP spoofing, rogue DHCP and link tamper alerts from TurtleTAK go out on the mesh through TurtleMesh, once you choose where alerts go in TurtleMesh's Alerts tab. Use a channel with its own key or a DM: these alerts can carry device names, IP and MAC addresses. |
| **One position** | The radio's GPS fix (a Heltec Wireless Tracker, T-Beam, RAK with GPS...) becomes the Hub's position in both. |
| **USB stays with the radio** | With the radio on USB, TurtleTAK's GPS reader leaves that port alone. |
| **Consoles link to each other** | Each web console has a button for the other one. |
| **One LED** | TurtleTAK drives the Hub's LED; TurtleMesh leaves it alone. |
| **Watchdog** | If either service stops, TurtleShell starts it again (at most once a minute each). Stopping the payload stops both. |

## Setup

1. Copy `payload.sh` to the Hub as its payload (web UI editor, `scp`, or USB) and run it.
2. Each service posts its **first web password** as a Hub notification. They are also in `/root/turtletak/web-password.txt` and `/root/turtlemesh/web-password.txt`.
3. **TurtleTAK** at `http://172.16.84.1:8484` > Setup: connect to your TAK Server (connection package, certificates, or enroll).
4. **TurtleMesh** at `http://172.16.84.1:8485` > Radio: the radio's address (Wi-Fi), or USB. Then choose where alerts go (Alerts tab) and, if you want them, the TAK chat bridge (TAK tab) and the Hub's position (Radio tab). Nothing goes out on a mesh channel until you do.
5. *Run at boot* is on by default in both, which keeps TurtleShell as the boot payload.

Running the payload again restarts both services with this version. Settings, certificates and logs are kept.

## LED

TurtleTAK's LED, as in its README: magenta while starting, yellow double while connecting to TAK, green single on TAK, red slow when setup is needed, and alert flashes.

## Files

| Path | |
|---|---|
| `/root/turtletak/` | TurtleTAK's settings, certificates, baselines and logs |
| `/root/turtlemesh/` | TurtleMesh's settings, certificates, node labels, chat history and logs |
| `/root/turtleshell/turtletak.sh`, `turtlemesh.sh` | The two payloads as run, written fresh from `payload.sh` every run |
| `/root/turtleshell/turtleshell.log` | Starts, restarts and stops |

## Requirements

- LAN Turtle Hub with Python 3
- A TAK Server for TurtleTAK, and a Meshtastic radio for TurtleMesh (Wi-Fi, or native USB such as the Heltec Wireless Tracker)
