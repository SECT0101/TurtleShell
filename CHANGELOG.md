# Changelog

TurtleShell versions (the payload in `payloads/library/general/TurtleShell-Hub`). Newest first.

## Hub Edition 1.0.1
- Carries TurtleTAK 1.0.2 and TurtleMesh 1.0.2: marker type and team color in TurtleTAK's Setup, chat replies, unread count and delete / clear chat, any friendly contact or anyone who messaged in the DM list, *Send alerts to*, *Set clock now*, and `CRITICAL` / `WARNING` alert wording on TAK and LoRa.

## Hub Edition 1.0.0
- First release: TurtleTAK 1.0.1 and TurtleMesh 1.0.1 on the LAN Turtle Hub from one payload.
- The two payloads are carried unchanged and started in order: TurtleTAK first, then TurtleMesh.
- Watchdog: a service that stops is started again, at most once a minute each. Stopping the payload stops both.
- TurtleTAK drives the Hub's LED; TurtleMesh leaves it alone.
- Working together: one TAK setup for both, TurtleTAK's alerts over LoRa, the radio's GPS as the Hub's position, the USB radio left alone by TurtleTAK's GPS reader, and consoles that link to each other.
- Windows line endings (pasted or saved on Windows) are fixed automatically.
- A `payload.sh` cut off while copying shows a Hub notification, a red LED and a log line instead of stopping silently.
