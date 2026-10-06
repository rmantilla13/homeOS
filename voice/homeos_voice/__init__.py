"""homeOS voice service.

Listens for the wake word on a USB mic, records one utterance, transcribes it
on the device and hands the text to the display over a local WebSocket. The
display sends the text to the assistant and asks this service to speak the
reply. Audio never leaves the device; see docs/VOICE.md.
"""

__version__ = "0.1.0"

# Bumped only when the WebSocket protocol changes incompatibly.
PROTOCOL_VERSION = "1"
