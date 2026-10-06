"""The voice unit has to join the display user's audio session."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_unit_uses_the_display_users_audio_session():
    unit = (ROOT / "deploy" / "homeos-voice.service").read_text()
    script = (ROOT / "deploy" / "install-voice.sh").read_text()
    assert "User=@USER@" in unit
    assert "Environment=XDG_RUNTIME_DIR=/run/user/@UID@" in unit
    assert "[ ! -S /run/user/@UID@/pulse/native ]" in unit
    assert 's/@USER@/$user/g' in script
    assert 's/@UID@/$uid/g' in script
    assert 'uid="$(id -u)"' in script
    assert "loginctl enable-linger" in script
