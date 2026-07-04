SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.NOTPARALLEL:

PROJECT_SANDBOX ?= claude-gh-ceec
BASE_SANDBOX ?= claude-wsl
NOVNC_SANDBOX ?= $(BASE_SANDBOX)
TMUX_SESSION ?= $(PROJECT_SANDBOX)
NOVNC_TMUX_SESSION ?= sbx-claude-novnc
HOST_PORT ?= 6080
LAN_RESOURCES ?= 192.168.8.0/24 192.168.9.0/24 192.168.10.0/24 192.168.11.0/24 192.168.12.0/24 192.168.110.0/24
LAN_CHECK_HOST ?= 192.168.11.42
WSL_HOST ?= gateway.docker.internal
WSL_CHECK_PORTS ?= 6379 8000 8080 18088 3306 9000

PROJECT_ROOT ?= /home/roshan/Developer/gh-ceec
LICENSE_ROOT ?= /home/roshan/Developer/gh-license-management
LICENSE_MOUNT ?= $(PROJECT_ROOT)/.sbx-workspaces/gh-license-management
SKILLS_ROOT ?= /home/roshan/Developer/skills
SKILLS_MOUNT ?= $(PROJECT_ROOT)/.sbx-workspaces/skills
GSSTACK_CONTAINER_ROOT ?= /home/roshan/Developer/gsstack-container
GSSTACK_CONTAINER_MOUNT ?= $(PROJECT_ROOT)/.sbx-workspaces/gsstack-container

.PHONY: help status dirty env-check allow-lan lan-check wsl-check stop shutdown daemon-stop recover restart attach shell bind-license bind-skills bind-gsstack-container bind-workspaces umount-license umount-skills umount-gsstack-container novnc-start novnc-stop

help:
	@printf '%s\n' \
	  'Targets:' \
	  '  make status        Show sbx, tmux, port, and bind-mount status' \
	  '  make dirty         Show git status for mounted workspaces' \
	  '  make stop          Stop noVNC, tmux session, and Claude sandboxes' \
	  '  make shutdown      Run stop, then stop sandboxd; safe before WSL/Windows shutdown' \
	  '  make recover       Recreate bind mount and restart the claude-gh-ceec tmux session' \
	  '  make restart       Restart only the claude-gh-ceec tmux/sbx session' \
	  '  make attach        Attach to the claude-gh-ceec tmux session' \
	  '  make shell         Open a shell inside claude-gh-ceec' \
	  '  make env-check     Check Tokyo locale/time and Claude login inside claude-gh-ceec' \
	  '  make allow-lan     Allow claude-gh-ceec to access configured LAN CIDRs' \
	  '  make lan-check     Check sandbox SSH access to LAN_CHECK_HOST' \
	  '  make wsl-check     Check sandbox access to WSL2 host services' \
	  '  make novnc-start   Start optional noVNC for claude-wsl' \
	  '  make novnc-stop    Stop optional noVNC for claude-wsl' \
	  '  make bind-license  Recreate gh-license-management bind mount' \
	  '  make bind-skills   Recreate skills bind mount' \
	  '  make bind-gsstack-container  Recreate gsstack-container bind mount' \
	  '  make umount-license  Unmount gh-license-management bind mount' \
	  '  make umount-skills   Unmount skills bind mount' \
	  '  make umount-gsstack-container  Unmount gsstack-container bind mount'

status:
	@echo '== sbx binary =='
	@command -v sbx
	@echo
	@echo '== sandboxes =='
	@sbx ls
	@echo
	@echo '== tmux sessions =='
	@tmux ls 2>/dev/null | grep -E '(^$(TMUX_SESSION):|^$(NOVNC_TMUX_SESSION):)' || true
	@echo
	@echo '== published ports =='
	@printf '%s: ' '$(PROJECT_SANDBOX)'; sbx ports '$(PROJECT_SANDBOX)' || true
	@printf '%s: ' '$(NOVNC_SANDBOX)'; sbx ports '$(NOVNC_SANDBOX)' || true
	@echo
	@echo '== bind mounts =='
	@if mountpoint -q '$(LICENSE_MOUNT)'; then \
	  findmnt -T '$(LICENSE_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	else \
	  echo 'missing: $(LICENSE_MOUNT)'; \
	fi
	@if mountpoint -q '$(SKILLS_MOUNT)'; then \
	  findmnt -T '$(SKILLS_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	else \
	  echo 'missing: $(SKILLS_MOUNT)'; \
	fi
	@if mountpoint -q '$(GSSTACK_CONTAINER_MOUNT)'; then \
	  findmnt -T '$(GSSTACK_CONTAINER_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	else \
	  echo 'missing: $(GSSTACK_CONTAINER_MOUNT)'; \
	fi

dirty:
	@echo '== $(PROJECT_ROOT) =='
	@git -C '$(PROJECT_ROOT)' status -sb || true
	@echo
	@echo '== $(LICENSE_ROOT) =='
	@git -C '$(LICENSE_ROOT)' status -sb || true
	@echo
	@echo '== $(SKILLS_ROOT) =='
	@git -C '$(SKILLS_ROOT)' status -sb || true
	@echo
	@echo '== $(GSSTACK_CONTAINER_ROOT) =='
	@git -C '$(GSSTACK_CONTAINER_ROOT)' status -sb || true

env-check:
	@sbx exec '$(PROJECT_SANDBOX)' sh -lc 'date; printf "TZ=%s LANG=%s LC_ALL=%s\n" "$$TZ" "$$LANG" "$$LC_ALL"; node -e "const r=Intl.DateTimeFormat().resolvedOptions(); console.log(JSON.stringify({timeZone:r.timeZone,locale:r.locale,offsetMinutes:new Date().getTimezoneOffset()}))"; claude auth status --json'

allow-lan:
	@for resource in $(LAN_RESOURCES); do \
	  if sbx policy ls '$(PROJECT_SANDBOX)' --type network | grep -Fq "$$resource"; then \
	    echo "Already allowed for $(PROJECT_SANDBOX): $$resource"; \
	  else \
	    sbx policy allow network --sandbox '$(PROJECT_SANDBOX)' "$$resource"; \
	  fi; \
	done

lan-check: allow-lan
	@echo '== tcp from $(PROJECT_SANDBOX) to $(LAN_CHECK_HOST):22 =='
	@sbx exec '$(PROJECT_SANDBOX)' sh -lc 'timeout 5 bash -lc "</dev/tcp/$(LAN_CHECK_HOST)/22" >/dev/null 2>&1 && echo "tcp open" || { echo "tcp blocked"; exit 1; }'
	@echo '== ssh handshake from $(PROJECT_SANDBOX) to $(LAN_CHECK_HOST) =='
	@sbx exec '$(PROJECT_SANDBOX)' sh -lc 'set +e; out=$$(timeout 8 ssh -o BatchMode=yes -o NumberOfPasswordPrompts=0 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/sbx-known-hosts-lan-check -o ConnectTimeout=6 -o PreferredAuthentications=none root@$(LAN_CHECK_HOST) true 2>&1); rc=$$?; printf "%s\n" "$$out" | sed -n "1,40p"; printf "%s\n" "$$out" | grep -Eq "Authorized users only|Permission denied|Authentications that can continue" && { echo "ssh reached auth stage"; exit 0; }; exit $$rc'

wsl-check:
	@echo '== WSL host alias from $(PROJECT_SANDBOX) =='
	@sbx exec '$(PROJECT_SANDBOX)' sh -lc 'getent hosts $(WSL_HOST); env | grep -Ei "^(http|https|no)_proxy=" | sort'
	@echo '== TCP checks via $(WSL_HOST) =='
	@for port in $(WSL_CHECK_PORTS); do \
	  sbx exec '$(PROJECT_SANDBOX)' sh -lc "timeout 5 bash -lc '</dev/tcp/$(WSL_HOST)/$$port' >/dev/null 2>&1" && \
	    echo "$(WSL_HOST):$$port open" || echo "$(WSL_HOST):$$port closed_or_blocked"; \
	done

stop: novnc-stop
	@echo 'Stopping tmux session: $(TMUX_SESSION)'
	@tmux kill-session -t '$(TMUX_SESSION)' 2>/dev/null || true
	@echo 'Stopping sandboxes: $(PROJECT_SANDBOX) $(BASE_SANDBOX)'
	@sbx stop '$(PROJECT_SANDBOX)' '$(BASE_SANDBOX)' || true

shutdown: stop daemon-stop
	@echo 'Done. It is safe to close WSL or shut down Windows.'

daemon-stop:
	@echo 'Stopping sandboxd'
	@sbx daemon stop || true

recover: allow-lan bind-workspaces restart
	@echo 'Recovered. Attach with: make attach'

restart:
	@echo 'Restarting tmux session: $(TMUX_SESSION)'
	@tmux kill-session -t '$(TMUX_SESSION)' 2>/dev/null || true
	@sbx stop '$(PROJECT_SANDBOX)' || true
	@tmux new-session -d -s '$(TMUX_SESSION)' 'cd $(PROJECT_ROOT) && sbx run --name $(PROJECT_SANDBOX)'
	@tmux ls | grep -E '^$(TMUX_SESSION):'

attach:
	@tmux attach -t '$(TMUX_SESSION)'

shell:
	@sbx exec -it -w '$(PROJECT_ROOT)' '$(PROJECT_SANDBOX)' bash

bind-license:
	@echo 'Ensuring local git exclude contains .sbx-workspaces/'
	@mkdir -p '$(PROJECT_ROOT)/.git/info'
	@grep -qxF '.sbx-workspaces/' '$(PROJECT_ROOT)/.git/info/exclude' 2>/dev/null || printf '\n.sbx-workspaces/\n' >> '$(PROJECT_ROOT)/.git/info/exclude'
	@mkdir -p '$(LICENSE_MOUNT)'
	@if mountpoint -q '$(LICENSE_MOUNT)'; then \
	  echo 'Already mounted: $(LICENSE_MOUNT)'; \
	  findmnt -T '$(LICENSE_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	else \
	  echo 'Mounting $(LICENSE_ROOT) -> $(LICENSE_MOUNT)'; \
	  sudo mount --bind '$(LICENSE_ROOT)' '$(LICENSE_MOUNT)'; \
	  findmnt -T '$(LICENSE_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	fi

bind-skills:
	@echo 'Ensuring local git exclude contains .sbx-workspaces/'
	@mkdir -p '$(PROJECT_ROOT)/.git/info'
	@grep -qxF '.sbx-workspaces/' '$(PROJECT_ROOT)/.git/info/exclude' 2>/dev/null || printf '\n.sbx-workspaces/\n' >> '$(PROJECT_ROOT)/.git/info/exclude'
	@mkdir -p '$(SKILLS_MOUNT)'
	@if mountpoint -q '$(SKILLS_MOUNT)'; then \
	  echo 'Already mounted: $(SKILLS_MOUNT)'; \
	  findmnt -T '$(SKILLS_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	else \
	  echo 'Mounting $(SKILLS_ROOT) -> $(SKILLS_MOUNT)'; \
	  sudo mount --bind '$(SKILLS_ROOT)' '$(SKILLS_MOUNT)'; \
	  findmnt -T '$(SKILLS_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	fi

bind-gsstack-container:
	@echo 'Ensuring local git exclude contains .sbx-workspaces/'
	@mkdir -p '$(PROJECT_ROOT)/.git/info'
	@grep -qxF '.sbx-workspaces/' '$(PROJECT_ROOT)/.git/info/exclude' 2>/dev/null || printf '\n.sbx-workspaces/\n' >> '$(PROJECT_ROOT)/.git/info/exclude'
	@mkdir -p '$(GSSTACK_CONTAINER_MOUNT)'
	@if mountpoint -q '$(GSSTACK_CONTAINER_MOUNT)'; then \
	  echo 'Already mounted: $(GSSTACK_CONTAINER_MOUNT)'; \
	  findmnt -T '$(GSSTACK_CONTAINER_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	else \
	  echo 'Mounting $(GSSTACK_CONTAINER_ROOT) -> $(GSSTACK_CONTAINER_MOUNT)'; \
	  sudo mount --bind '$(GSSTACK_CONTAINER_ROOT)' '$(GSSTACK_CONTAINER_MOUNT)'; \
	  findmnt -T '$(GSSTACK_CONTAINER_MOUNT)' -o TARGET,SOURCE,FSTYPE,OPTIONS; \
	fi

bind-workspaces: bind-license bind-skills bind-gsstack-container

umount-license:
	@if mountpoint -q '$(LICENSE_MOUNT)'; then \
	  echo 'Unmounting $(LICENSE_MOUNT)'; \
	  sudo umount '$(LICENSE_MOUNT)'; \
	else \
	  echo 'Not mounted: $(LICENSE_MOUNT)'; \
	fi

umount-skills:
	@if mountpoint -q '$(SKILLS_MOUNT)'; then \
	  echo 'Unmounting $(SKILLS_MOUNT)'; \
	  sudo umount '$(SKILLS_MOUNT)'; \
	else \
	  echo 'Not mounted: $(SKILLS_MOUNT)'; \
	fi

umount-gsstack-container:
	@if mountpoint -q '$(GSSTACK_CONTAINER_MOUNT)'; then \
	  echo 'Unmounting $(GSSTACK_CONTAINER_MOUNT)'; \
	  sudo umount '$(GSSTACK_CONTAINER_MOUNT)'; \
	else \
	  echo 'Not mounted: $(GSSTACK_CONTAINER_MOUNT)'; \
	fi

novnc-start:
	@HOST_PORT='$(HOST_PORT)' ./scripts/start-claude-tokyo-novnc.sh '$(NOVNC_SANDBOX)'

novnc-stop:
	@echo 'Stopping optional noVNC for $(NOVNC_SANDBOX)'
	@if sbx ls | awk -v name='$(NOVNC_SANDBOX)' '$$1 == name && $$3 == "running" { found=1 } END { exit found ? 0 : 1 }'; then \
	  HOST_PORT='$(HOST_PORT)' ./scripts/stop-claude-tokyo-novnc.sh '$(NOVNC_SANDBOX)' || true; \
	else \
	  tmux kill-session -t '$(NOVNC_TMUX_SESSION)' 2>/dev/null || true; \
	  sbx ports '$(NOVNC_SANDBOX)' --unpublish '0.0.0.0:$(HOST_PORT):6080/tcp4' >/dev/null 2>&1 || true; \
	  sbx ports '$(NOVNC_SANDBOX)' --unpublish '127.0.0.1:$(HOST_PORT):6080' --unpublish '[::1]:$(HOST_PORT):6080' >/dev/null 2>&1 || true; \
	  echo 'noVNC sandbox is not running; only stale tmux/ports were cleaned.'; \
	fi
