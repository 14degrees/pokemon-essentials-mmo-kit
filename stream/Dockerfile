# One PLAYER's game, streamed to a browser tab. Built on neko (github.com/m1k1o/neko):
# an X display, PulseAudio, a WebRTC server and a web page with the video, the audio
# and the keyboard in it. This image adds Wine and the game itself; each friend gets
# one container (stream/gen.sh), logs in with their password, and plays their own
# character - the game connects to the PEMK server like any other client.
#
# Build context is the REPO ROOT (the game folder: Game.exe, Data/, Graphics/, Audio/,
# Plugins/...), so build with:   docker build -f stream/Dockerfile -t pemk-play .
# or through stream/docker-compose.yml. stream/Dockerfile.dockerignore keeps the
# server, the docs and the git history out of the context.
ARG BASE_IMAGE=ghcr.io/m1k1o/neko/base:latest
FROM $BASE_IMAGE

# Wine (the game is a 64-bit Windows build of mkxp-z), a window manager to keep the
# game maximized, and software OpenGL for the virtual display.
RUN set -eux; apt-get update; \
    apt-get install -y --no-install-recommends wine wine64 openbox libgl1-mesa-dri mesa-utils; \
    apt-get clean -y; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# The game, owned by the neko user: the client writes its config, its log and its
# local save next to Game.exe.
COPY --chown=neko:neko . /opt/pemk/game
COPY --chown=neko:neko stream/start.sh /opt/pemk/start.sh
COPY stream/supervisord.conf /etc/neko/supervisord/pemk.conf
COPY stream/openbox.xml /etc/neko/openbox.xml
RUN chmod +x /opt/pemk/start.sh; \
    rm -f /opt/pemk/game/mmo_config*.txt /opt/pemk/game/mmo_session*.dat /opt/pemk/game/mmo_account*.dat /opt/pemk/game/mmo*.log; \
    # the Wine prefix lives on a volume (compose): the directory exists here, owned by
    # neko, so the volume takes that ownership on its first mount
    mkdir -p /home/neko/.wine; chown neko:neko /home/neko/.wine

# Where the game finds its server: the compose file sets these per deployment.
ENV PEMK_HOST=host.docker.internal \
    PEMK_PORT=9998 \
    PEMK_INSTANCE=player \
    PEMK_SCREEN=1024x768 \
    WINEDEBUG=-all \
    LIBGL_ALWAYS_SOFTWARE=1
