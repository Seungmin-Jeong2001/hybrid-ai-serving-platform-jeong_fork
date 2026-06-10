#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

HA_PROJECT_NAME="hybrid-ai-serving-platform"
HA_MARKER="managed-by:${HA_PROJECT_NAME}:ha"

die() {
  printf 'ha: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

script_dir() {
  local source="${BASH_SOURCE[0]}"
  local dir

  while [[ -L "$source" ]]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="${dir}/${source}"
  done

  cd -P "$(dirname "$source")" && pwd
}

HA_PROJECT_ROOT="$(script_dir)"
HA_OPENSTACK_DIR="${HA_PROJECT_ROOT}/private/openstack"
HA_OPENSTACK_BOOTSTRAP_DIR="${HA_PROJECT_ROOT}/private/kubernetes-bootstrap"
HA_REVERSE_PROXY_DIR="${HA_PROJECT_ROOT}/private/reverse-proxy"
HA_DEPS_DIR="${HA_DEPS_DIR:-${HA_PROJECT_ROOT}/.ha/bin}"
HA_COMPLETION_DIR="${HA_COMPLETION_DIR:-${HA_PROJECT_ROOT}/.ha/completions}"
HA_HANDOFF_DIR="${HA_HANDOFF_DIR:-${HA_PROJECT_ROOT}/.ha/handoff}"
HA_ENV_FILE="${HA_ENV_FILE:-${HA_PROJECT_ROOT}/.env}"
HA_SECRET_ENV_FILE="${HA_SECRET_ENV_FILE:-${HA_PROJECT_ROOT}/.env.secret}"
HA_LOCAL_KUBECONFIG_DEFAULT="${HA_PROJECT_ROOT}/.ha/kubeconfig"
PATH="${HA_DEPS_DIR}:${PATH}"
export PATH

current_git_root() {
  git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || true
}

require_project_context() {
  local cwd_root
  cwd_root="$(current_git_root)"

  if [[ "$cwd_root" != "$HA_PROJECT_ROOT" ]]; then
    cat >&2 <<EOF
ha is scoped to:
  ${HA_PROJECT_ROOT}

Run it from this repository path only.
EOF
    exit 64
  fi
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || die "required command not found: ${tool}"
}

usage() {
  cat <<EOF
Usage:
  ./ha install [--bin-dir DIR] [--force] [--no-shell-config] [--with-deps]
  ha doctor
  ha ci
  ha test [--strict] [--terraform-init] [--integration]
  ha apply [--run-mode apply|reinstall] [--phases provision|platform|registry|finalize|all] [--validate-gpu] [--require-backend-config]
  ha destroy [--cleanup-devstack] [--require-backend-config]
  ha up local|lxd|openstack-local|openstack|openstack-kubernetes|kubernetes|storage|gpu|all [--auto-approve]
  ha prod check
  ha env init|check|path|example|secret-example
  ha proxy validate|path [local|cloudflare]
  ha explain
  ha completion bash|zsh
  ha status
  ha tf <terraform-args...>
  ha k8s render|diff|apply <kubernetes|storage|gpu|all> [kubectl-args...]
  ha uninstall [--bin-dir DIR]

Commands:
  install    Install the Hybrid AI project CLI launcher in the first writable PATH location
  uninstall  Remove the managed launcher
  doctor     Check project layout and local tool availability
  ci         Run the private-cloud CI script used by GitHub Actions
  test       Run smoke/integration validation without applying changes
  apply      Run the private-cloud apply script used by GitHub Actions
  destroy    Run the private-cloud destroy script used by GitHub Actions
  up         Provision local Kubernetes or apply OpenStack/Kubernetes targets
  prod       Check production readiness of the active Kubernetes target
  env        Create or check the local private-cloud env file
  proxy      Validate or locate Caddy reverse proxy config
  explain    Show the local workflow and required environment variables
  completion Print shell completion script for bash or zsh
  status     Show git branch status for this repository
  tf         Run terraform inside private/openstack
  k8s        Run kubectl against private-cloud kustomize directories
  path       Print this project root
  help       Show this help

Examples:
  ./ha install
  ./ha install --with-deps
  ./ha install --bin-dir /opt/homebrew/bin
  ha doctor
  ha ci
  ha test
  ha env init
  vi .env
  ha env check
  ha proxy validate
  ha test --integration
  ha prod check
  ha explain
  ha completion zsh
  ha apply --run-mode apply
  ha apply --run-mode reinstall
  ha destroy
  ha up all --auto-approve
  ha prod check
  ha up openstack-local --auto-approve
  ha up openstack --auto-approve
  ha tf fmt -check -recursive
  ha tf init
  ha k8s render kubernetes
  ha k8s apply storage
  ha proxy path cloudflare
EOF
}

explain() {
  cat <<EOF
ha는 Hybrid AI 프로젝트 이름을 딴 repository 전용 CLI입니다.
현재 git root가 ${HA_PROJECT_ROOT}일 때만 실행되며, 다른 repository에서는 동작하지 않습니다.
HA_* 환경 변수는 이 프로젝트 전용 prefix이며, High Availability 약자가 아닙니다.

1. 설치

  ./ha install
  ./ha install --with-deps

  - ./ha install은 ha launcher를 PATH에 설치합니다.
  - ./ha install --with-deps는 terraform과 kubectl을 project-local .ha/bin에 설치합니다.
  - ha install은 bash/zsh 자동완성 파일을 .ha/completions에 생성하고 shell config에 연결합니다.
  - .ha/bin은 git에 커밋하지 않는 로컬 도구 디렉터리입니다.
  - 버전을 고정하려면 HA_TERRAFORM_VERSION, HA_KUBECTL_VERSION을 지정합니다.

2. 테스트

  ha test
  ha test --terraform-init
  ha test --integration

  - ha test는 실제 OpenStack/Kubernetes 리소스를 만들지 않습니다.
  - ha test --terraform-init은 OpenStack Terraform provider를 내려받고 validate까지 수행합니다.
  - ha test --integration은 선택 provider 기준으로 변경 전 검증을 수행합니다.
  - ha env init으로 .env와 .env.secret 템플릿을 만들면 ha가 자동으로 읽습니다.
  - 기본 .env는 HA_PROVIDER=auto와 Kubernetes provisioning 옵션만 둡니다.
  - auto provider는 sudo 가능 시 local, 아니면 LXD를 선택합니다.
  - .env.secret은 local/LXD provider에서는 보통 비어 있습니다.

3. 실제 반영

  ha up local --auto-approve
  ha up all --auto-approve
  ha up openstack-local --auto-approve
  ha up openstack --auto-approve
  ha up kubernetes
  ha up storage
  ha up gpu

  - 기본 provider는 auto입니다.
  - ha up local은 현재 서버에 kubeadm 기반 Kubernetes를 설치하고 kubeconfig를 .ha/kubeconfig로 받습니다.
  - ha up lxd는 sudo 없이 LXD 컨테이너 안에 kubeadm 기반 Kubernetes를 설치합니다.
  - ha up openstack-local은 LXD 컨테이너 안에 DevStack 기반 로컬 OpenStack control plane을 설치합니다.
  - ha up all은 provider가 local/LXD이면 Kubernetes provisioning 후 Kubernetes baseline manifest를 적용합니다.
  - ha up openstack은 HA_PROVIDER=openstack일 때 Terraform apply로 OpenStack 리소스를 생성/변경합니다.
  - ha up openstack-kubernetes는 Terraform output node inventory를 기준으로 Kubernetes를 bootstrap합니다.
  - ha up kubernetes|storage|gpu는 현재 kubeconfig 대상 cluster에 manifest를 적용합니다.
  - storage/gpu는 기본 all에 포함하지 않습니다. HA_APPLY_STORAGE=1, HA_APPLY_GPU=1일 때 local all에 포함합니다.
  - ha prod check는 현재 kubeconfig 대상이 production 기준을 만족하는지 검사합니다.
  - 단일 node local/LXD cluster는 접속 테스트용이며 production 기준에는 실패합니다.

4. 필요한 환경 변수

  Provider 기본값:
    HA_PROVIDER=auto
    HA_CLUSTER_NAME=hybrid-ai-private
    HA_LOCAL_KUBECONFIG=.ha/kubeconfig

  OpenStack provider를 선택한 경우에만:
    OS_AUTH_URL
    OS_PROJECT_NAME 또는 OS_PROJECT_ID
    OS_USER_DOMAIN_NAME
    OS_PROJECT_DOMAIN_NAME
    OS_USERNAME
    OS_PASSWORD

  OpenStack mode에서 SSH public key는 없으면 .ha/ssh 아래에 자동 생성해서 Terraform에 전달합니다.
  로컬 OpenStack control plane은 HA_OPENSTACK_CONTAINER, HA_DEVSTACK_BRANCH, HA_DEVSTACK_PASSWORD로 조정합니다.
  OpenStack VM bootstrap은 HA_OPENSTACK_SSH_USER, HA_OPENSTACK_SSH_TARGET, HA_OPENSTACK_SSH_PROXY_CONTAINER로 조정합니다.

5. 자주 쓰는 순서

  ./ha install --with-deps
  ha env init
  vi .env
  ha env check
  ha doctor
  ha test --terraform-init
  ha test --integration
  ha up all --auto-approve

6. 자동완성

  ha completion zsh
  ha completion bash

  - ha install 이후 새 shell을 열면 ha 명령과 옵션을 tab으로 완성할 수 있습니다.
  - zsh/bash 모두 ambiguous completion은 후보를 아래에 보여주는 방식으로 설정합니다.
  - 현재 shell에서 바로 적용하려면 zsh에서는 source .ha/completions/ha.zsh를 실행합니다.
  - bash에서는 source .ha/completions/ha.bash를 실행합니다.

7. Reverse proxy

  ha proxy validate
  ha proxy path cloudflare

  - Caddy 설정은 private/reverse-proxy에 있습니다.
  - ssh.intp.me는 Caddy가 아니라 Tailscale SSH 진입점으로 둡니다.
  - openstack.intp.me, k8s.intp.me, grafana.intp.me, argocd.intp.me는 Caddy가 Host header로 분기합니다.
  - Cloudflare token은 .env.secret 또는 GitHub Secret에만 둡니다.
EOF
}

required_project_paths() {
  printf '%s\n' \
    "${HA_OPENSTACK_DIR}/main.tf" \
    "${HA_OPENSTACK_DIR}/variables.tf" \
    "${HA_PROJECT_ROOT}/private/ci/private-cloud-ci.sh" \
    "${HA_PROJECT_ROOT}/private/ci/private-cloud-apply.sh" \
    "${HA_PROJECT_ROOT}/private/ci/private-cloud-destroy.sh" \
    "${HA_OPENSTACK_BOOTSTRAP_DIR}/bootstrap-k8s.sh" \
    "${HA_REVERSE_PROXY_DIR}/Caddyfile" \
    "${HA_REVERSE_PROXY_DIR}/Caddyfile.internal-tls" \
    "${HA_REVERSE_PROXY_DIR}/cloudflare_dns.py" \
    "${HA_PROJECT_ROOT}/private/kubernetes/kustomization.yaml" \
    "${HA_PROJECT_ROOT}/private/storage/kustomization.yaml" \
    "${HA_PROJECT_ROOT}/private/gpu-worker/kustomization.yaml" \
    "${HA_PROJECT_ROOT}/.github/workflows/private-cloud-remote.yml" \
    "${HA_PROJECT_ROOT}/.github/workflows/private-cloud-plan.yml" \
    "${HA_PROJECT_ROOT}/.github/workflows/private-cloud-controller.yml"
}

default_launcher_locations() {
  printf '%s\n' \
    "/opt/homebrew/bin/ha" \
    "/usr/local/bin/ha" \
    "${HOME}/.local/bin/ha"
}

is_managed_launcher() {
  local target="$1"
  local link_target

  if [[ -L "$target" ]]; then
    link_target="$(readlink "$target")"
    if [[ "$link_target" != /* ]]; then
      link_target="$(cd -P "$(dirname "$target")" && pwd)/${link_target}"
    fi
    [[ "$link_target" == "${HA_PROJECT_ROOT}/ha" ]] && return 0
  fi

  grep -qF "$HA_MARKER" "$target" 2>/dev/null
}

write_launcher() {
  local target="$1"
  local tmp

  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf '# %s\n' "$HA_MARKER"
    printf 'project_root=%q\n' "$HA_PROJECT_ROOT"
    printf '%s\n' 'project_script="${project_root}/ha"'
    printf '%s\n' 'cwd_root="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || true)"'
    printf '%s\n' 'if [[ "${cwd_root}" != "${project_root}" ]]; then'
    printf '%s\n' '  printf "ha is scoped to:\n  %s\n\nRun it from that repository only.\n" "${project_root}" >&2'
    printf '%s\n' '  exit 64'
    printf '%s\n' 'fi'
    printf '%s\n' 'exec "${project_script}" "$@"'
  } >"$tmp"
  chmod 755 "$tmp"
  mv "$tmp" "$target"
}

shell_config_files() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"

  case "$shell_name" in
    zsh)
      printf '%s\n' "${HOME}/.zshrc" "${HOME}/.zprofile"
      ;;
    bash)
      printf '%s\n' "${HOME}/.bashrc" "${HOME}/.bash_profile"
      ;;
    *)
      printf '%s\n' "${HOME}/.profile"
      ;;
  esac
}

completion_bash() {
  cat <<'EOF'
if [[ "$-" == *i* ]]; then
  bind 'set show-all-if-ambiguous on' 2>/dev/null || true
  bind 'set show-all-if-unmodified on' 2>/dev/null || true
  bind '"\t": complete' 2>/dev/null || true
fi

_ha_completion() {
  local cur prev command
  COMPREPLY=()

  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  command="${COMP_WORDS[1]:-}"

  if [[ "$COMP_CWORD" -eq 1 ]]; then
    COMPREPLY=($(compgen -W "install uninstall doctor test up prod production env proxy caddy explain guide completion status tf terraform k8s kubectl path help" -- "$cur"))
    return
  fi

  case "$command" in
    install)
      if [[ "$prev" == "--bin-dir" ]]; then
        compopt -o filenames 2>/dev/null || true
        COMPREPLY=($(compgen -d -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--bin-dir --force --no-shell-config --with-deps --deps" -- "$cur"))
      fi
      ;;
    uninstall)
      if [[ "$prev" == "--bin-dir" ]]; then
        compopt -o filenames 2>/dev/null || true
        COMPREPLY=($(compgen -d -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--bin-dir" -- "$cur"))
      fi
      ;;
    test)
      COMPREPLY=($(compgen -W "--strict --terraform-init --integration" -- "$cur"))
      ;;
    up)
      if [[ "$cur" == --* ]]; then
        COMPREPLY=($(compgen -W "--auto-approve" -- "$cur"))
      elif [[ "$COMP_CWORD" -eq 2 ]]; then
        COMPREPLY=($(compgen -W "local lxd server openstack-local devstack openstack openstack-kubernetes openstack-k8s terraform kubernetes foundation base storage gpu gpu-worker k8s all" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--auto-approve" -- "$cur"))
      fi
      ;;
    prod|production)
      COMPREPLY=($(compgen -W "check" -- "$cur"))
      ;;
    k8s|kubectl)
      if [[ "$COMP_CWORD" -eq 2 ]]; then
        COMPREPLY=($(compgen -W "render diff apply" -- "$cur"))
      elif [[ "$COMP_CWORD" -eq 3 ]]; then
        COMPREPLY=($(compgen -W "kubernetes foundation base storage gpu gpu-worker all" -- "$cur"))
      fi
      ;;
    tf|terraform)
      if [[ "$COMP_CWORD" -eq 2 ]]; then
        COMPREPLY=($(compgen -W "init validate fmt plan apply destroy output providers state version workspace" -- "$cur"))
      fi
      ;;
    completion)
      COMPREPLY=($(compgen -W "bash zsh" -- "$cur"))
      ;;
    env)
      COMPREPLY=($(compgen -W "init check path example secret-example" -- "$cur"))
      ;;
    proxy|caddy)
      if [[ "$COMP_CWORD" -eq 2 ]]; then
        COMPREPLY=($(compgen -W "validate path" -- "$cur"))
      elif [[ "$COMP_CWORD" -eq 3 ]]; then
        COMPREPLY=($(compgen -W "local cloudflare http https" -- "$cur"))
      fi
      ;;
  esac
}

complete -F _ha_completion ha
EOF
}

completion_zsh() {
  cat <<'EOF'
#compdef ha

setopt auto_list
unsetopt menu_complete
unsetopt auto_menu
zstyle ':completion:*' menu no
zstyle ':completion:*' verbose yes
bindkey '^I' complete-word 2>/dev/null || true

_ha() {
  local -a commands install_opts uninstall_opts test_opts apply_opts destroy_opts up_targets up_opts prod_actions k8s_actions k8s_targets completion_shells env_actions proxy_actions proxy_profiles terraform_commands

  commands=(
    'install:install launcher and optional dependencies'
    'uninstall:remove managed launcher'
    'doctor:check project layout and local tools'
    'ci:run GitHub Actions private-cloud CI script'
    'test:run smoke or integration validation'
    'apply:run GitHub Actions private-cloud apply script'
    'destroy:run GitHub Actions private-cloud destroy script'
    'up:apply OpenStack Terraform or Kubernetes manifests'
    'prod:check production readiness'
    'production:alias for prod'
    'env:create or check the local private-cloud env file'
    'proxy:validate or locate Caddy reverse proxy config'
    'caddy:alias for proxy'
    'explain:show local workflow and required environment variables'
    'guide:alias for explain'
    'completion:print shell completion script'
    'status:show git status'
    'tf:run terraform in private/openstack'
    'terraform:alias for tf'
    'k8s:run kubectl against private-cloud kustomize directories'
    'kubectl:alias for k8s'
    'path:print project root'
    'help:show help'
  )

  install_opts=(
    '--bin-dir:install launcher into a specific directory'
    '--force:replace managed launcher or reinstall dependencies'
    '--no-shell-config:do not update shell startup files'
    '--with-deps:install terraform and kubectl into .ha/bin'
    '--deps:alias for --with-deps'
  )
  uninstall_opts=('--bin-dir:remove launcher from a specific directory')
  test_opts=(
    '--strict:treat skipped checks as failures'
    '--terraform-init:download providers and run terraform validate'
    '--integration:run terraform plan and Kubernetes server dry-run'
  )
  apply_opts=(
    '--run-mode:apply from existing DevStack or reinstall DevStack first'
    '--validate-gpu:run GPU validation after apply'
    '--require-backend-config:fail if Terraform backend config is empty'
  )
  destroy_opts=(
    '--cleanup-devstack:remove local DevStack container after Terraform destroy'
    '--require-backend-config:fail if Terraform backend config is empty'
  )
  up_targets=(local lxd server openstack-local devstack openstack openstack-kubernetes openstack-k8s terraform kubernetes foundation base storage gpu gpu-worker k8s all)
  up_opts=('--auto-approve:apply OpenStack Terraform without prompting')
  prod_actions=(check)
  k8s_actions=(render diff apply)
  k8s_targets=(kubernetes foundation base storage gpu gpu-worker all)
  completion_shells=(bash zsh)
  env_actions=(init check path example secret-example)
  proxy_actions=(validate path)
  proxy_profiles=(local cloudflare http https)
  terraform_commands=(init validate fmt plan apply destroy output providers state version workspace)

  if (( CURRENT == 2 )); then
    _describe -t commands 'ha command' commands
    return
  fi

  case "${words[2]}" in
    install)
      if [[ "${words[CURRENT-1]}" == "--bin-dir" ]]; then
        _files -/
      else
        _describe -t options 'install option' install_opts
      fi
      ;;
    uninstall)
      if [[ "${words[CURRENT-1]}" == "--bin-dir" ]]; then
        _files -/
      else
        _describe -t options 'uninstall option' uninstall_opts
      fi
      ;;
    test)
      _describe -t options 'test option' test_opts
      ;;
    ci)
      _describe -t options 'ci option' test_opts
      ;;
    apply)
      if [[ "${words[CURRENT-1]}" == "--run-mode" ]]; then
        _values 'run mode' apply reinstall
      else
        _describe -t options 'apply option' apply_opts
      fi
      ;;
    destroy)
      _describe -t options 'destroy option' destroy_opts
      ;;
    up)
      if (( CURRENT == 3 )); then
        _values 'target' $up_targets
      else
        _describe -t options 'up option' up_opts
      fi
      ;;
    prod|production)
      if (( CURRENT == 3 )); then
        _values 'action' $prod_actions
      fi
      ;;
    k8s|kubectl)
      if (( CURRENT == 3 )); then
        _values 'action' $k8s_actions
      elif (( CURRENT == 4 )); then
        _values 'target' $k8s_targets
      else
        _normal
      fi
      ;;
    tf|terraform)
      if (( CURRENT == 3 )); then
        _values 'terraform command' $terraform_commands
      else
        _normal
      fi
      ;;
    completion)
      if (( CURRENT == 3 )); then
        _values 'shell' $completion_shells
      fi
      ;;
    env)
      if (( CURRENT == 3 )); then
        _values 'action' $env_actions
      fi
      ;;
    proxy|caddy)
      if (( CURRENT == 3 )); then
        _values 'action' $proxy_actions
      elif (( CURRENT == 4 )); then
        _values 'profile' $proxy_profiles
      fi
      ;;
  esac
}

autoload -Uz compinit
if ! whence -w compdef >/dev/null 2>&1; then
  compinit >/dev/null 2>&1 || true
fi
if whence -w compdef >/dev/null 2>&1; then
  compdef _ha ha
fi
EOF
}

completion_script() {
  local shell="${1:-}"

  case "$shell" in
    bash)
      completion_bash
      ;;
    zsh)
      completion_zsh
      ;;
    *)
      die "usage: ha completion bash|zsh"
      ;;
  esac
}

install_completion_files() {
  mkdir -p "$HA_COMPLETION_DIR"
  completion_bash >"${HA_COMPLETION_DIR}/ha.bash"
  completion_zsh >"${HA_COMPLETION_DIR}/ha.zsh"
  info "Installed shell completions in ${HA_COMPLETION_DIR}"
}

append_shell_config() {
  local file="$1"
  local updated=0

  touch "$file"
  if grep -qF "$HA_MARKER" "$file" 2>/dev/null; then
    if ! grep -qF '$HA_HOME/.ha/bin' "$file" 2>/dev/null; then
      cat >>"$file" <<EOF

# Hybrid AI Serving Platform CLI dependencies
# ${HA_MARKER}
case ":\$PATH:" in
  *":\$HA_HOME/.ha/bin:"*) ;;
  *) export PATH="\$HA_HOME/.ha/bin:\$PATH" ;;
esac
EOF
      info "Updated shell config dependency PATH: ${file}"
      updated=1
    fi

    if ! grep -qF '$HA_HOME/.ha/completions' "$file" 2>/dev/null; then
      cat >>"$file" <<EOF

# Hybrid AI Serving Platform CLI completion
# ${HA_MARKER}
case "\$-" in
  *i*)
    if [ -n "\${ZSH_VERSION:-}" ] && [ -f "\$HA_HOME/.ha/completions/ha.zsh" ]; then
      autoload -Uz compinit
      if [[ -z "\${_comps:-}" ]]; then
        compinit >/dev/null 2>&1 || true
      fi
      source "\$HA_HOME/.ha/completions/ha.zsh"
    elif [ -n "\${BASH_VERSION:-}" ] && [ -f "\$HA_HOME/.ha/completions/ha.bash" ]; then
      source "\$HA_HOME/.ha/completions/ha.bash"
    fi
    ;;
esac
EOF
      info "Updated shell config completion: ${file}"
      updated=1
    fi

    [[ "$updated" -eq 1 ]] || info "Shell config already contains ha setup: ${file}"
    return
  fi

  cat >>"$file" <<EOF

# Hybrid AI Serving Platform CLI
# ${HA_MARKER}
export HA_HOME="${HA_PROJECT_ROOT}"
case ":\$PATH:" in
  *":\$HA_HOME/.ha/bin:"*) ;;
  *) export PATH="\$HA_HOME/.ha/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":\$HOME/.local/bin:"*) ;;
  *) export PATH="\$HOME/.local/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":\$HA_HOME:"*) ;;
  *) export PATH="\$HA_HOME:\$PATH" ;;
esac
case "\$-" in
  *i*)
    if [ -n "\${ZSH_VERSION:-}" ] && [ -f "\$HA_HOME/.ha/completions/ha.zsh" ]; then
      autoload -Uz compinit
      if [[ -z "\${_comps:-}" ]]; then
        compinit >/dev/null 2>&1 || true
      fi
      source "\$HA_HOME/.ha/completions/ha.zsh"
    elif [ -n "\${BASH_VERSION:-}" ] && [ -f "\$HA_HOME/.ha/completions/ha.bash" ]; then
      source "\$HA_HOME/.ha/completions/ha.bash"
    fi
    ;;
esac
EOF
  info "Updated shell config: ${file}"
}

install_shell_config() {
  local seen=""
  local file

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    case ":${seen}:" in
      *":${file}:"*) continue ;;
    esac
    seen="${seen}:${file}"
    append_shell_config "$file"
  done < <(shell_config_files)
}

platform_os() {
  case "$(uname -s)" in
    Linux)
      printf '%s\n' linux
      ;;
    Darwin)
      printf '%s\n' darwin
      ;;
    *)
      die "unsupported OS for dependency install: $(uname -s)"
      ;;
  esac
}

platform_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s\n' amd64
      ;;
    arm64|aarch64)
      printf '%s\n' arm64
      ;;
    *)
      die "unsupported CPU architecture for dependency install: $(uname -m)"
      ;;
  esac
}

download_file() {
  local url="$1"
  local target="$2"

  curl -fsSL "$url" -o "$target"
}

sha256_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi

  die "required command not found: sha256sum or shasum"
}

verify_sha256() {
  local expected="$1"
  local path="$2"
  local actual

  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] || die "checksum mismatch for $(basename "$path")"
}

latest_terraform_version() {
  local json
  local version

  if [[ -n "${HA_TERRAFORM_VERSION:-}" ]]; then
    printf '%s\n' "$HA_TERRAFORM_VERSION"
    return
  fi

  json="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform)" ||
    die "could not resolve Terraform version; set HA_TERRAFORM_VERSION"

  version="$(printf '%s\n' "$json" | sed -n 's/.*"current_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ -n "$version" ]] || die "could not parse Terraform version; set HA_TERRAFORM_VERSION"
  printf '%s\n' "$version"
}

latest_kubectl_version() {
  if [[ -n "${HA_KUBECTL_VERSION:-}" ]]; then
    printf '%s\n' "$HA_KUBECTL_VERSION"
    return
  fi

  curl -fsSL https://dl.k8s.io/release/stable.txt ||
    die "could not resolve kubectl version; set HA_KUBECTL_VERSION"
}

extract_terraform_archive() {
  local archive="$1"
  local target_dir="$2"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" "$target_dir" <<'PY'
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
target_dir = pathlib.Path(sys.argv[2])

with zipfile.ZipFile(archive) as zf:
    zf.extract("terraform", target_dir)

binary = target_dir / "terraform"
binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
PY
    return
  fi

  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$archive" terraform -d "$target_dir"
    chmod 755 "${target_dir}/terraform"
    return
  fi

  if [[ "$(uname -s)" == "Darwin" ]] && command -v ditto >/dev/null 2>&1; then
    ditto -x -k "$archive" "$target_dir"
    chmod 755 "${target_dir}/terraform"
    return
  fi

  die "required command not found: python3, unzip, or ditto"
}

install_terraform_dep() {
  local force="$1"
  local os
  local arch
  local version
  local filename
  local tmp_dir
  local archive
  local sums
  local expected

  if [[ "$force" -eq 0 && -x "${HA_DEPS_DIR}/terraform" ]]; then
    info "Dependency already installed: ${HA_DEPS_DIR}/terraform"
    return
  fi

  os="$(platform_os)"
  arch="$(platform_arch)"
  version="$(latest_terraform_version)"
  filename="terraform_${version}_${os}_${arch}.zip"
  tmp_dir="$(mktemp -d)"
  archive="${tmp_dir}/${filename}"
  sums="${tmp_dir}/terraform_${version}_SHA256SUMS"

  info "Installing terraform ${version} to ${HA_DEPS_DIR}"
  download_file "https://releases.hashicorp.com/terraform/${version}/${filename}" "$archive"
  download_file "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_SHA256SUMS" "$sums"

  expected="$(awk -v file="$filename" '$2 == file { print $1 }' "$sums")"
  [[ -n "$expected" ]] || die "could not find checksum for ${filename}"
  verify_sha256 "$expected" "$archive"

  extract_terraform_archive "$archive" "$tmp_dir"
  install -m 755 "${tmp_dir}/terraform" "${HA_DEPS_DIR}/terraform"
  rm -rf "$tmp_dir"
}

install_kubectl_dep() {
  local force="$1"
  local os
  local arch
  local version
  local tmp_dir
  local binary
  local checksum
  local expected

  if [[ "$force" -eq 0 && -x "${HA_DEPS_DIR}/kubectl" ]]; then
    info "Dependency already installed: ${HA_DEPS_DIR}/kubectl"
    return
  fi

  os="$(platform_os)"
  arch="$(platform_arch)"
  version="$(latest_kubectl_version)"
  tmp_dir="$(mktemp -d)"
  binary="${tmp_dir}/kubectl"
  checksum="${tmp_dir}/kubectl.sha256"

  info "Installing kubectl ${version} to ${HA_DEPS_DIR}"
  download_file "https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl" "$binary"
  download_file "https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl.sha256" "$checksum"

  expected="$(tr -d '[:space:]' <"$checksum")"
  [[ -n "$expected" ]] || die "could not find checksum for kubectl ${version}"
  verify_sha256 "$expected" "$binary"

  install -m 755 "$binary" "${HA_DEPS_DIR}/kubectl"
  rm -rf "$tmp_dir"
}

install_project_deps() {
  local force="$1"

  require_tool curl
  require_tool install

  mkdir -p "$HA_DEPS_DIR"
  install_terraform_dep "$force"
  install_kubectl_dep "$force"
  info "Installed project dependencies in ${HA_DEPS_DIR}"
}

install_launcher() {
  local bin_dir="${HA_BIN_DIR:-}"
  local deps=0
  local force=0
  local shell_config=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-dir)
        [[ $# -ge 2 ]] || die "--bin-dir requires a value"
        bin_dir="$2"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      --with-deps|--deps)
        deps=1
        shift
        ;;
      --no-shell-config)
        shell_config=0
        shift
        ;;
      *)
        die "unknown install option: $1"
        ;;
    esac
  done

  [[ -f "${HA_PROJECT_ROOT}/ha" ]] || die "project ha script not found: ${HA_PROJECT_ROOT}/ha"
  [[ -x "${HA_PROJECT_ROOT}/ha" ]] || chmod +x "${HA_PROJECT_ROOT}/ha"

  local locations=()
  if [[ -n "$bin_dir" ]]; then
    mkdir -p "$bin_dir"
    locations=("${bin_dir}/ha")
  else
    mkdir -p "${HOME}/.local/bin"
    while IFS= read -r location; do
      locations+=("$location")
    done < <(default_launcher_locations)
  fi

  local target
  local target_dir
  local installed=""

  for target in "${locations[@]}"; do
    target_dir="$(dirname "$target")"
    [[ -d "$target_dir" && -w "$target_dir" ]] || continue

    if [[ -e "$target" || -L "$target" ]]; then
      if ! is_managed_launcher "$target"; then
        if [[ "$force" -eq 1 || -n "$bin_dir" ]]; then
          [[ "$force" -eq 1 ]] || die "${target} already exists; pass --force to replace it"
        else
          info "Skipping unmanaged launcher: ${target}"
          continue
        fi
      fi
    fi

    write_launcher "$target"
    installed="$target"
    break
  done

  [[ -n "$installed" ]] || die "could not install ha launcher; pass --bin-dir with a writable directory"

  info "Installed ${installed}"
  install_completion_files
  [[ "$deps" -eq 0 ]] || install_project_deps "$force"
  [[ "$shell_config" -eq 0 ]] || install_shell_config
  info "Open a new shell, or source your shell config, then run: ha doctor"
}

uninstall_launcher() {
  local bin_dir="${HA_BIN_DIR:-${HOME}/.local/bin}"
  local custom_bin_dir=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-dir)
        [[ $# -ge 2 ]] || die "--bin-dir requires a value"
        bin_dir="$2"
        custom_bin_dir=1
        shift 2
        ;;
      *)
        die "unknown uninstall option: $1"
        ;;
    esac
  done

  local targets=()
  local target
  local removed=0

  if [[ "$custom_bin_dir" -eq 1 ]]; then
    targets=("${bin_dir}/ha")
  else
    while IFS= read -r target; do
      targets+=("$target")
    done < <(default_launcher_locations)
  fi

  for target in "${targets[@]}"; do
    [[ -e "$target" || -L "$target" ]] || continue
    is_managed_launcher "$target" || continue
    rm -f "$target"
    removed=1
    info "Removed ${target}"
  done

  [[ "$removed" -eq 1 ]] || die "no managed ha launcher found"
  info "Shell config entries are left in place; remove ${HA_MARKER} blocks manually if needed."
}

doctor() {
  local failed=0
  local path

  info "Project: ${HA_PROJECT_ROOT}"

  if command -v git >/dev/null 2>&1; then
    info "ok: git"
  else
    info "fail: git is missing"
    failed=1
  fi

  while IFS= read -r path; do
    if [[ -e "$path" ]]; then
      info "ok: ${path#${HA_PROJECT_ROOT}/}"
    else
      info "fail: missing ${path#${HA_PROJECT_ROOT}/}"
      failed=1
    fi
  done < <(required_project_paths)

  if command -v terraform >/dev/null 2>&1; then
    info "ok: terraform"
    terraform -chdir="$HA_OPENSTACK_DIR" fmt -check -recursive >/dev/null || failed=1
  else
    info "warn: terraform is not installed"
  fi

  if command -v kubectl >/dev/null 2>&1; then
    info "ok: kubectl"
    for target in kubernetes storage gpu-worker; do
      kubectl kustomize "${HA_PROJECT_ROOT}/private/${target}" >/dev/null || failed=1
    done
  else
    info "warn: kubectl is not installed"
  fi

  [[ "$failed" -eq 0 ]] || die "doctor found problems"
}

HA_TEST_FAILED=0
HA_TEST_SKIPPED=0
HA_TEST_STRICT=0

test_ok() {
  info "ok: $*"
}

test_skip() {
  HA_TEST_SKIPPED=$((HA_TEST_SKIPPED + 1))
  if [[ "$HA_TEST_STRICT" -eq 1 ]]; then
    info "fail: $*"
    HA_TEST_FAILED=1
  else
    info "skip: $*"
  fi
}

test_fail() {
  info "fail: $*"
  HA_TEST_FAILED=1
}

test_project_layout() {
  local path
  local missing=0

  while IFS= read -r path; do
    if [[ ! -e "$path" ]]; then
      info "missing: ${path#${HA_PROJECT_ROOT}/}"
      missing=1
    fi
  done < <(required_project_paths)

  if [[ "$missing" -eq 0 ]]; then
    test_ok "project layout"
  else
    test_fail "project layout"
  fi
}

test_bash_syntax() {
  if bash -n "${HA_PROJECT_ROOT}/ha"; then
    test_ok "ha bash syntax"
  else
    test_fail "ha bash syntax"
  fi
}

test_caddy_config() {
  local output

  if ! command -v caddy >/dev/null 2>&1; then
    test_skip "Caddy config validation (caddy not installed)"
    return
  fi

  if output="$(caddy validate --config "$(caddy_config_path local)" --adapter caddyfile 2>&1)"; then
    test_ok "Caddy local config"
  else
    [[ -z "$output" ]] || info "$output"
    test_fail "Caddy local config"
  fi
}

kustomize_dirs() {
  printf '%s\n' \
    "${HA_PROJECT_ROOT}/private/kubernetes" \
    "${HA_PROJECT_ROOT}/private/storage" \
    "${HA_PROJECT_ROOT}/private/gpu-worker"
}

kustomization_resources() {
  local kustomization="$1"

  awk '
    /^[[:space:]]*resources:[[:space:]]*$/ {
      in_resources = 1
      next
    }
    in_resources && /^[^[:space:]-]/ {
      in_resources = 0
    }
    in_resources && /^[[:space:]]*-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "") {
        print line
      }
    }
  ' "$kustomization"
}

test_kustomization_references() {
  local dir
  local resource
  local missing=0

  while IFS= read -r dir; do
    while IFS= read -r resource; do
      case "$resource" in
        /*|http://*|https://*|git::*)
          continue
          ;;
      esac

      if [[ ! -e "${dir}/${resource}" ]]; then
        info "missing: ${dir#${HA_PROJECT_ROOT}/}/${resource}"
        missing=1
      fi
    done < <(kustomization_resources "${dir}/kustomization.yaml")
  done < <(kustomize_dirs)

  if [[ "$missing" -eq 0 ]]; then
    test_ok "kustomization resource references"
  else
    test_fail "kustomization resource references"
  fi
}

test_yaml_syntax() {
  local output
  local rc

  if ! command -v python3 >/dev/null 2>&1; then
    test_skip "YAML syntax (python3 not installed)"
    return
  fi

  set +e
  output="$(python3 - "${HA_PROJECT_ROOT}" <<'PY' 2>&1
import pathlib
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(2)

root = pathlib.Path(sys.argv[1])
paths = sorted(
    path
    for pattern in ("*.yaml", "*.yml")
    for path in root.rglob(pattern)
    if ".git" not in path.parts and ".ha" not in path.parts
)

failed = False
for path in paths:
    try:
        with path.open("r", encoding="utf-8") as handle:
            list(yaml.safe_load_all(handle))
    except Exception as exc:
        print(f"{path.relative_to(root)}: {exc}", file=sys.stderr)
        failed = True

sys.exit(1 if failed else 0)
PY
)"
  rc=$?
  set -e

  case "$rc" in
    0)
      test_ok "YAML syntax"
      ;;
    2)
      test_skip "YAML syntax (python3 PyYAML not installed)"
      ;;
    *)
      [[ -z "$output" ]] || info "$output"
      test_fail "YAML syntax"
      ;;
  esac
}

test_terraform_static() {
  local terraform_init="$1"
  local output

  if ! command -v terraform >/dev/null 2>&1; then
    test_skip "terraform checks (terraform not installed)"
    return
  fi

  local terraform_fmt_files=()
  local terraform_path
  local terraform_relpath

  while IFS= read -r terraform_path; do
    case "$terraform_path" in
      private/openstack/*.tf|private/openstack/*.tfvars)
        terraform_relpath="${terraform_path#private/openstack/}"
        terraform_fmt_files+=("$terraform_relpath")
        ;;
    esac
  done < <(git -C "$HA_PROJECT_ROOT" ls-files private/openstack)

  if [[ "${#terraform_fmt_files[@]}" -eq 0 ]]; then
    test_skip "terraform fmt (no tracked Terraform files)"
  elif output="$(terraform -chdir="$HA_OPENSTACK_DIR" fmt -check "${terraform_fmt_files[@]}" 2>&1)"; then
    test_ok "terraform fmt"
  else
    [[ -z "$output" ]] || info "$output"
    test_fail "terraform fmt"
  fi

  if [[ "$terraform_init" -eq 1 ]]; then
    if output="$(terraform -chdir="$HA_OPENSTACK_DIR" init -backend=false 2>&1)"; then
      test_ok "terraform init -backend=false"
    else
      [[ -z "$output" ]] || info "$output"
      test_fail "terraform init -backend=false"
      return
    fi
  fi

  if [[ ! -d "${HA_OPENSTACK_DIR}/.terraform" ]]; then
    test_skip "terraform validate (.terraform missing; run ha test --terraform-init)"
    return
  fi

  if output="$(terraform -chdir="$HA_OPENSTACK_DIR" validate 2>&1)"; then
    test_ok "terraform validate"
  else
    [[ -z "$output" ]] || info "$output"
    test_fail "terraform validate"
  fi
}

test_kustomize_render() {
  local dir
  local output

  if command -v kubectl >/dev/null 2>&1; then
    while IFS= read -r dir; do
      if output="$(kubectl kustomize "$dir" 2>&1 >/dev/null)"; then
        test_ok "kubectl kustomize ${dir#${HA_PROJECT_ROOT}/}"
      else
        [[ -z "$output" ]] || info "$output"
        test_fail "kubectl kustomize ${dir#${HA_PROJECT_ROOT}/}"
      fi
    done < <(kustomize_dirs)
    return
  fi

  if command -v kustomize >/dev/null 2>&1; then
    while IFS= read -r dir; do
      if output="$(kustomize build "$dir" 2>&1 >/dev/null)"; then
        test_ok "kustomize build ${dir#${HA_PROJECT_ROOT}/}"
      else
        [[ -z "$output" ]] || info "$output"
        test_fail "kustomize build ${dir#${HA_PROJECT_ROOT}/}"
      fi
    done < <(kustomize_dirs)
    return
  fi

  test_skip "kustomize render (kubectl or kustomize not installed)"
}

required_terraform_env() {
  true
}

env_template() {
  cat <<'EOF'
# Hybrid AI Serving Platform local environment.
# ha sources this file automatically from the repository root.
#
# Default mode picks direct local provisioning when sudo is available, otherwise LXD.
export HA_PROVIDER="${HA_PROVIDER:-auto}"
export HA_CLUSTER_NAME="${HA_CLUSTER_NAME:-hybrid-ai-private}"
export HA_LOCAL_KUBECONFIG="${HA_LOCAL_KUBECONFIG:-.ha/kubeconfig}"
export HA_LXD_CONTAINER="${HA_LXD_CONTAINER:-ha-k8s}"
export HA_OPENSTACK_CONTAINER="${HA_OPENSTACK_CONTAINER:-ha-openstack}"

# Kubernetes install settings for local/LXD/OpenStack VM provisioning.
export HA_K8S_VERSION_MINOR="${HA_K8S_VERSION_MINOR:-v1.36}"
export HA_K8S_POD_CIDR="${HA_K8S_POD_CIDR:-192.168.0.0/16}"
export HA_K8S_CNI_MANIFEST="${HA_K8S_CNI_MANIFEST:-https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml}"
export HA_K8S_KUBEADM_IGNORE_PREFLIGHT="${HA_K8S_KUBEADM_IGNORE_PREFLIGHT:-NumCPU}"

# Local OpenStack control plane settings for ha up openstack-local.
export HA_OPENSTACK_LXD_IMAGE="${HA_OPENSTACK_LXD_IMAGE:-ubuntu:24.04}"
export HA_DEVSTACK_BRANCH="${HA_DEVSTACK_BRANCH:-master}"
export HA_DEVSTACK_PASSWORD="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
export HA_DEVSTACK_LIBVIRT_TYPE="${HA_DEVSTACK_LIBVIRT_TYPE:-auto}"
export HA_OPENSTACK_PERSISTENT_STORAGE="${HA_OPENSTACK_PERSISTENT_STORAGE:-true}"
export HA_OPENSTACK_PERSISTENT_DIR="${HA_OPENSTACK_PERSISTENT_DIR:-.ha/openstack/persistent}"
export HA_OPENSTACK_GLANCE_STORE_DIR="${HA_OPENSTACK_GLANCE_STORE_DIR:-${HA_OPENSTACK_PERSISTENT_DIR}/glance-images}"
export HA_OPENSTACK_NOVA_INSTANCES_DIR="${HA_OPENSTACK_NOVA_INSTANCES_DIR:-${HA_OPENSTACK_PERSISTENT_DIR}/nova-instances}"
export TF_BACKEND_TYPE="${TF_BACKEND_TYPE:-s3}"

# OpenStack VM Kubernetes bootstrap settings.
export HA_OPENSTACK_KUBECONFIG="${HA_OPENSTACK_KUBECONFIG:-.ha/openstack/kubeconfig}"
export HA_OPENSTACK_SSH_USER="${HA_OPENSTACK_SSH_USER:-ubuntu}"
export HA_OPENSTACK_SSH_TARGET="${HA_OPENSTACK_SSH_TARGET:-auto}"
export HA_K8S_API_ENDPOINT="${HA_K8S_API_ENDPOINT:-}"
# export HA_OPENSTACK_SSH_PROXY_CONTAINER="ha-openstack"

# Baseline Kubernetes manifests are applied by default after provisioning.
# Storage and GPU examples need real NFS/GPU backing, so keep them opt-in.
export HA_APPLY_STORAGE="${HA_APPLY_STORAGE:-0}"
export HA_APPLY_GPU="${HA_APPLY_GPU:-0}"

# DNS and Caddy reverse proxy settings.
# DNS names are configuration, not secrets. Keep tokens in .env.secret.
export HA_BASE_DOMAIN="${HA_BASE_DOMAIN:-intp.me}"
export HA_TAILSCALE_IP="${HA_TAILSCALE_IP:-100.64.0.10}"
export HA_SSH_DOMAIN="${HA_SSH_DOMAIN:-ssh.${HA_BASE_DOMAIN}}"
export HA_OPENSTACK_DOMAIN="${HA_OPENSTACK_DOMAIN:-openstack.${HA_BASE_DOMAIN}}"
export HA_K8S_DOMAIN="${HA_K8S_DOMAIN:-k8s.${HA_BASE_DOMAIN}}"
export HA_GRAFANA_DOMAIN="${HA_GRAFANA_DOMAIN:-grafana.${HA_BASE_DOMAIN}}"
export HA_ARGOCD_DOMAIN="${HA_ARGOCD_DOMAIN:-argocd.${HA_BASE_DOMAIN}}"
export HA_CADDY_ACME_EMAIL="${HA_CADDY_ACME_EMAIL:-admin@${HA_BASE_DOMAIN}}"
export HA_OPENSTACK_HORIZON_UPSTREAM="${HA_OPENSTACK_HORIZON_UPSTREAM:-127.0.0.1:18081}"
export HA_K8S_DASHBOARD_UPSTREAM="${HA_K8S_DASHBOARD_UPSTREAM:-127.0.0.1:18082}"
export HA_GRAFANA_UPSTREAM="${HA_GRAFANA_UPSTREAM:-127.0.0.1:3000}"
export HA_ARGOCD_UPSTREAM="${HA_ARGOCD_UPSTREAM:-127.0.0.1:8080}"
export HA_CLOUDFLARE_DNS_TTL="${HA_CLOUDFLARE_DNS_TTL:-120}"
export HA_DNS_SERVICES="${HA_DNS_SERVICES:-openstack,k8s,grafana,argocd,git}"
# Cloudflare zone ID is not a secret. Put the API token in .env.secret.
# export CLOUDFLARE_ZONE_ID=""

# OpenStack is an optional provider now. Only set these when using:
#   HA_PROVIDER=openstack ha up all --auto-approve
# export HA_PROVIDER="openstack"
# export OS_AUTH_URL=""
# export OS_PROJECT_NAME=""
# export OS_USER_DOMAIN_NAME="Default"
# export OS_PROJECT_DOMAIN_NAME="Default"
# export OS_REGION_NAME="RegionOne"
EOF
}

secret_env_template() {
  cat <<'EOF'
# Hybrid AI Serving Platform local secrets.
# ha sources this file after .env when it exists.
# Do not commit this file.

# Local provider normally needs no secrets here.
#
# OpenStack provider credentials, only needed when HA_PROVIDER=openstack.
# export OS_USERNAME=""
# export OS_PASSWORD=""

# Existing Kubernetes access, only needed when applying to an already-created cluster.
# export KUBECONFIG="/path/to/private-cluster-kubeconfig"
# export PRIVATE_CLOUD_KUBECONFIG_B64="base64-encoded-kubeconfig"

# Cloudflare DNS automation and Caddy DNS-01 certificate issuance.
# Required permissions: Zone:Read and DNS:Edit scoped to the intp.me zone.
# export CLOUDFLARE_API_TOKEN=""

# Optional Terraform remote state backend for shared apply/destroy workflows.
# export TF_BACKEND_CONFIG='bucket="REPLACE"
# key="private-cloud/terraform.tfstate"
# region="REPLACE"
# endpoint="REPLACE"
# access_key="REPLACE"
# secret_key="REPLACE"
# skip_credentials_validation=true
# skip_region_validation=true
# skip_metadata_api_check=true
# force_path_style=true'
EOF
}

load_env_file() {
  if [[ -f "$HA_ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$HA_ENV_FILE"
    set +a
  fi

  if [[ -f "$HA_SECRET_ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$HA_SECRET_ENV_FILE"
    set +a
  fi
}

env_file_has_placeholders() {
  [[ -f "$HA_ENV_FILE" ]] || return 1
  awk '
    /^[[:space:]]*#/ { next }
    /REPLACE_WITH|example\.com|CHANGE_ME|PUBLIC_KEY_ONLY/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$HA_ENV_FILE"
}

env_value_is_placeholder() {
  local value="$1"

  case "$value" in
    *REPLACE_WITH*|*CHANGE_ME*|*PUBLIC_KEY_ONLY*|*example.com*|*example.invalid*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

HA_PROMPT_PASSWORD=0
HA_OPENSTACK_OPTION_CONSUMED=0

parse_openstack_option() {
  HA_OPENSTACK_OPTION_CONSUMED=0

  case "${1:-}" in
    --auth-url)
      [[ $# -ge 2 ]] || die "--auth-url requires a value"
      export OS_AUTH_URL="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --username)
      [[ $# -ge 2 ]] || die "--username requires a value"
      export OS_USERNAME="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --password)
      [[ $# -ge 2 ]] || die "--password requires a value"
      export OS_PASSWORD="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --password-env)
      [[ $# -ge 2 ]] || die "--password-env requires a value"
      [[ -n "${!2:-}" ]] || die "--password-env variable is empty or unset: $2"
      export OS_PASSWORD="${!2}"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --prompt-password)
      HA_PROMPT_PASSWORD=1
      HA_OPENSTACK_OPTION_CONSUMED=1
      ;;
    --cloud)
      [[ $# -ge 2 ]] || die "--cloud requires a value"
      export OS_CLOUD="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --project|--project-name)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      export OS_PROJECT_NAME="$2"
      export OS_TENANT_NAME="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --project-id)
      [[ $# -ge 2 ]] || die "--project-id requires a value"
      export OS_PROJECT_ID="$2"
      export OS_TENANT_ID="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --user-domain)
      [[ $# -ge 2 ]] || die "--user-domain requires a value"
      export OS_USER_DOMAIN_NAME="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --user-domain-id)
      [[ $# -ge 2 ]] || die "--user-domain-id requires a value"
      export OS_USER_DOMAIN_ID="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --project-domain)
      [[ $# -ge 2 ]] || die "--project-domain requires a value"
      export OS_PROJECT_DOMAIN_NAME="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --project-domain-id)
      [[ $# -ge 2 ]] || die "--project-domain-id requires a value"
      export OS_PROJECT_DOMAIN_ID="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
    --region)
      [[ $# -ge 2 ]] || die "--region requires a value"
      export OS_REGION_NAME="$2"
      export TF_VAR_region="$2"
      HA_OPENSTACK_OPTION_CONSUMED=2
      ;;
  esac
}

prepare_openstack_auth() {
  if [[ -z "${OS_USER_DOMAIN_NAME:-}" && -z "${OS_USER_DOMAIN_ID:-}" && -z "${OS_DEFAULT_DOMAIN_NAME:-}" && -z "${OS_DEFAULT_DOMAIN_ID:-}" ]]; then
    export OS_USER_DOMAIN_NAME="Default"
  fi

  if [[ -z "${OS_PROJECT_DOMAIN_NAME:-}" && -z "${OS_PROJECT_DOMAIN_ID:-}" && -z "${OS_DEFAULT_DOMAIN_NAME:-}" && -z "${OS_DEFAULT_DOMAIN_ID:-}" ]]; then
    export OS_PROJECT_DOMAIN_NAME="Default"
  fi

  if [[ "$HA_PROMPT_PASSWORD" -eq 1 && -z "${OS_PASSWORD:-}" ]]; then
    [[ -r /dev/tty ]] || die "cannot prompt for password without a TTY"
    printf 'OpenStack password for %s: ' "${OS_USERNAME:-user}" >/dev/tty
    IFS= read -r -s OS_PASSWORD </dev/tty
    printf '\n' >/dev/tty
    export OS_PASSWORD
  fi
}

provider_requested() {
  printf '%s\n' "${HA_PROVIDER:-auto}"
}

lxd_available() {
  command -v lxc >/dev/null 2>&1 && lxc version >/dev/null 2>&1
}

current_provider() {
  local provider="${HA_PROVIDER:-auto}"

  if [[ "$provider" == "auto" ]]; then
    if can_run_privileged; then
      provider="local"
    elif lxd_available; then
      provider="lxd"
    else
      provider="local"
    fi
  fi

  printf '%s\n' "$provider"
}

local_kubeconfig_path() {
  local path="${HA_LOCAL_KUBECONFIG:-${HA_LOCAL_KUBECONFIG_DEFAULT}}"
  if [[ "$path" != /* ]]; then
    path="${HA_PROJECT_ROOT}/${path}"
  fi
  printf '%s\n' "$path"
}

openstack_kubeconfig_path() {
  local path="${HA_OPENSTACK_KUBECONFIG:-${HA_PROJECT_ROOT}/.ha/openstack/kubeconfig}"
  if [[ "$path" != /* ]]; then
    path="${HA_PROJECT_ROOT}/${path}"
  fi
  printf '%s\n' "$path"
}

have_passwordless_sudo() {
  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

can_run_privileged() {
  [[ "$(id -u)" -eq 0 ]] || have_passwordless_sudo
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

require_privileged() {
  if can_run_privileged; then
    return
  fi

  cat >&2 <<'EOF'
ha: local provisioning needs root privileges.

This machine requires a sudo password, and this non-interactive session cannot
enter it. Run `sudo -v` in this shell and retry, or run `sudo ./ha up all --auto-approve`.
EOF
  exit 1
}

run_env() {
  local action="check"
  HA_PROMPT_PASSWORD=0

  if [[ $# -gt 0 && "$1" != --* ]]; then
    action="$1"
    shift
  fi

  load_env_file

  while [[ $# -gt 0 ]]; do
    parse_openstack_option "$@"
    case "$HA_OPENSTACK_OPTION_CONSUMED" in
      1)
        shift
        ;;
      2)
        shift 2
        ;;
      *)
        die "unknown env option: $1"
        ;;
    esac
  done

  case "$action" in
    init)
      mkdir -p "$(dirname "$HA_ENV_FILE")"
      if [[ -e "$HA_ENV_FILE" ]]; then
        info "Env file already exists: ${HA_ENV_FILE}"
      else
        env_template >"$HA_ENV_FILE"
        chmod 600 "$HA_ENV_FILE"
        info "Created env file: ${HA_ENV_FILE}"
      fi

      if [[ ! -e "$HA_SECRET_ENV_FILE" ]]; then
        secret_env_template >"$HA_SECRET_ENV_FILE"
        chmod 600 "$HA_SECRET_ENV_FILE"
        info "Created secret env file: ${HA_SECRET_ENV_FILE}"
      else
        info "Secret env file already exists: ${HA_SECRET_ENV_FILE}"
      fi
      info "Edit it, then run: ha env check"
      ;;
    check)
      if [[ ! -f "$HA_ENV_FILE" ]]; then
        info "Env file not found: ${HA_ENV_FILE}"
        info "Create it with: ha env init"
        return 1
      fi

      if env_file_has_placeholders; then
        info "warn: ${HA_ENV_FILE} still contains example or placeholder values"
      fi

      case "$(current_provider)" in
        local|server)
          info "ok: provider $(current_provider)"
          info "ok: local kubeconfig path $(local_kubeconfig_path)"
          if can_run_privileged; then
            info "ok: privileged local provisioning is available"
          else
            info "warn: sudo password is required before local provisioning can install Kubernetes"
          fi
          ;;
        lxd)
          info "ok: provider lxd"
          info "ok: local kubeconfig path $(local_kubeconfig_path)"
          if lxd_available; then
            info "ok: LXD is available"
          else
            info "fail: LXD is not available"
            return 1
          fi
          ;;
        openstack)
          prepare_openstack_auth
          if test_integration_env; then
            info "Env file is usable for OpenStack/Terraform checks."
          else
            return 1
          fi
          ;;
        *)
          info "fail: unknown HA_PROVIDER=$(current_provider)"
          return 1
          ;;
      esac
      ;;
    path)
      info "$HA_ENV_FILE"
      info "$HA_SECRET_ENV_FILE"
      ;;
    example)
      env_template
      ;;
    secret-example)
      secret_env_template
      ;;
    *)
      die "usage: ha env init|check|path|example|secret-example"
      ;;
  esac
}

caddy_config_path() {
  local profile="${1:-local}"

  case "$profile" in
    local|http)
      printf '%s\n' "${HA_REVERSE_PROXY_DIR}/Caddyfile"
      ;;
    cloudflare|https)
      printf '%s\n' "${HA_REVERSE_PROXY_DIR}/Caddyfile.cloudflare"
      ;;
    *)
      die "unknown proxy profile: ${profile}"
      ;;
  esac
}

run_proxy() {
  local action="${1:-validate}"
  local profile="${2:-local}"
  local config
  local output

  load_env_file
  config="$(caddy_config_path "$profile")"

  case "$action" in
    path)
      info "$config"
      ;;
    validate)
      require_tool caddy
      if [[ "$profile" == "cloudflare" || "$profile" == "https" ]] && [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        die "CLOUDFLARE_API_TOKEN is required to validate the cloudflare Caddy profile"
      fi

      if output="$(caddy validate --config "$config" --adapter caddyfile 2>&1)"; then
        info "ok: Caddy config ${config#${HA_PROJECT_ROOT}/}"
      else
        [[ -z "$output" ]] || info "$output"
        die "Caddy config validation failed"
      fi
      ;;
    *)
      die "usage: ha proxy validate|path [local|cloudflare]"
      ;;
  esac
}

test_integration_env() {
  local name
  local missing=0

  prepare_openstack_auth
  ensure_openstack_ssh_public_key

  if [[ -n "${OS_CLOUD:-}" ]]; then
    if env_value_is_placeholder "$OS_CLOUD"; then
      info "placeholder env: OS_CLOUD"
      missing=1
    fi
  else
    for name in OS_AUTH_URL OS_USERNAME OS_PASSWORD; do
      if [[ -z "${!name:-}" ]]; then
        info "missing env: ${name}"
        missing=1
      elif env_value_is_placeholder "${!name}"; then
        info "placeholder env: ${name}"
        missing=1
      fi
    done

    if [[ -z "${OS_PROJECT_ID:-}" && -z "${OS_TENANT_ID:-}" && -z "${OS_PROJECT_NAME:-}" && -z "${OS_TENANT_NAME:-}" ]]; then
      info "missing env: OS_PROJECT_NAME or OS_PROJECT_ID"
      missing=1
    elif [[ -n "${OS_PROJECT_NAME:-}" ]] && env_value_is_placeholder "$OS_PROJECT_NAME"; then
      info "placeholder env: OS_PROJECT_NAME"
      missing=1
    elif [[ -n "${OS_PROJECT_ID:-}" ]] && env_value_is_placeholder "$OS_PROJECT_ID"; then
      info "placeholder env: OS_PROJECT_ID"
      missing=1
    fi
  fi

  while IFS= read -r name; do
    if [[ -z "${!name:-}" ]]; then
      info "missing env: ${name}"
      missing=1
    elif env_value_is_placeholder "${!name}"; then
      info "placeholder env: ${name}"
      missing=1
    fi
  done < <(required_terraform_env)

  if [[ "$missing" -eq 0 ]]; then
    test_ok "OpenStack/Terraform integration environment"
  else
    test_fail "OpenStack/Terraform integration environment"
    return 1
  fi
}

test_terraform_plan() {
  local output
  local plan_file

  prepare_openstack_auth

  if ! command -v terraform >/dev/null 2>&1; then
    test_fail "terraform integration checks (terraform not installed)"
    return 1
  fi

  if ! test_integration_env; then
    return 1
  fi

  if output="$(terraform -chdir="$HA_OPENSTACK_DIR" init -backend=false 2>&1)"; then
    test_ok "terraform init -backend=false"
  else
    [[ -z "$output" ]] || info "$output"
    test_fail "terraform init -backend=false"
    return 1
  fi

  if output="$(terraform -chdir="$HA_OPENSTACK_DIR" validate 2>&1)"; then
    test_ok "terraform validate"
  else
    [[ -z "$output" ]] || info "$output"
    test_fail "terraform validate"
    return 1
  fi

  plan_file="$(mktemp "${HA_OPENSTACK_DIR}/private-cloud.XXXXXX.tfplan")"
  if output="$(terraform -chdir="$HA_OPENSTACK_DIR" plan -out="$plan_file" 2>&1)"; then
    test_ok "terraform plan"
  else
    rm -f "$plan_file"
    [[ -z "$output" ]] || info "$output"
    test_fail "terraform plan"
    return 1
  fi

  rm -f "$plan_file"
}

HA_KUBECONFIG_DECODED=0

configure_kubeconfig_from_env() {
  local kubeconfig_b64

  HA_KUBECONFIG_DECODED=0

  if [[ -n "${KUBECONFIG:-}" ]]; then
    return 0
  fi

  if [[ -f "$(openstack_kubeconfig_path)" ]]; then
    KUBECONFIG="$(openstack_kubeconfig_path)"
    export KUBECONFIG
    return 0
  fi

  kubeconfig_b64="${PRIVATE_CLOUD_KUBECONFIG_B64:-}"
  if [[ -z "$kubeconfig_b64" ]]; then
    return 0
  fi

  local kubeconfig
  kubeconfig="$(mktemp)"
  if printf "%s" "$kubeconfig_b64" | base64 -d >"$kubeconfig"; then
    chmod 600 "$kubeconfig"
    export KUBECONFIG="$kubeconfig"
    HA_KUBECONFIG_DECODED=1
    return 0
  else
    rm -f "$kubeconfig"
    return 1
  fi
}

prepare_kubeconfig() {
  case "$(current_provider)" in
    local|server|lxd)
      if [[ -f "$(local_kubeconfig_path)" ]]; then
        KUBECONFIG="$(local_kubeconfig_path)"
        export KUBECONFIG
        return
      fi
      test_fail "local kubeconfig not found; run ha up all --auto-approve"
      ;;
    *)
      if configure_kubeconfig_from_env; then
        if [[ "$HA_KUBECONFIG_DECODED" -eq 1 ]]; then
          test_ok "decoded PRIVATE_CLOUD_KUBECONFIG_B64"
        fi
        if [[ -z "${KUBECONFIG:-}" ]]; then
          test_fail "OpenStack kubeconfig not found; run ha up openstack-kubernetes --auto-approve or set KUBECONFIG"
        fi
      else
        test_fail "decode PRIVATE_CLOUD_KUBECONFIG_B64"
      fi
      ;;
  esac
}

test_kubernetes_cluster() {
  local apply_changes="$1"
  local dir
  local output
  local kubectl_action=(apply --dry-run=server -k)

  if ! command -v kubectl >/dev/null 2>&1; then
    test_fail "kubernetes integration checks (kubectl not installed)"
    return 1
  fi

  prepare_kubeconfig

  if output="$(kubectl cluster-info 2>&1)"; then
    test_ok "kubernetes cluster access"
  else
    [[ -z "$output" ]] || info "$output"
    test_fail "kubernetes cluster access"
    return 1
  fi

  if [[ "$apply_changes" -eq 1 ]]; then
    kubectl_action=(apply -k)
  fi

  while IFS= read -r dir; do
    if output="$(kubectl "${kubectl_action[@]}" "$dir" 2>&1)"; then
      if [[ "$apply_changes" -eq 1 ]]; then
        test_ok "kubectl apply ${dir#${HA_PROJECT_ROOT}/}"
      else
        test_ok "kubectl server dry-run ${dir#${HA_PROJECT_ROOT}/}"
      fi
    else
      [[ -z "$output" ]] || info "$output"
      if [[ "$apply_changes" -eq 1 ]]; then
        test_fail "kubectl apply ${dir#${HA_PROJECT_ROOT}/}"
      else
        test_fail "kubectl server dry-run ${dir#${HA_PROJECT_ROOT}/}"
      fi
    fi
  done < <(kustomize_dirs)
}

ensure_openstack_ssh_public_key() {
  local key_path="${HA_SSH_KEY_PATH:-${HA_PROJECT_ROOT}/.ha/ssh/hybrid-ai-private-admin}"
  local key_dir

  if [[ -n "${TF_VAR_ssh_public_key:-}" ]]; then
    return
  fi

  key_dir="$(dirname "$key_path")"
  mkdir -p "$key_dir"

  if [[ ! -f "${key_path}.pub" ]]; then
    require_tool ssh-keygen
    ssh-keygen -t ed25519 -N "" -C "hybrid-ai-private-admin" -f "$key_path" >/dev/null
    chmod 600 "$key_path"
  fi

  TF_VAR_ssh_public_key="$(<"${key_path}.pub")"
  export TF_VAR_ssh_public_key
}

write_openstack_handoff() {
  local output_file="${HA_HANDOFF_DIR}/openstack-output.json"

  mkdir -p "$HA_HANDOFF_DIR"
  if terraform -chdir="$HA_OPENSTACK_DIR" output -json >"$output_file"; then
    chmod 600 "$output_file"
    info "Wrote OpenStack handoff: ${output_file#${HA_PROJECT_ROOT}/}"
  fi
}

configure_local_kubeconfig() {
  local kubeconfig
  kubeconfig="$(local_kubeconfig_path)"

  if [[ -f "$kubeconfig" ]]; then
    export KUBECONFIG="$kubeconfig"
    return 0
  fi

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    mkdir -p "$(dirname "$kubeconfig")"
    if run_privileged cat /etc/kubernetes/admin.conf >"$kubeconfig"; then
      chmod 600 "$kubeconfig"
      export KUBECONFIG="$kubeconfig"
      return 0
    fi
  fi

  return 1
}

configure_k8s_node_packages_local() {
  require_tool curl
  require_privileged

  run_privileged bash -s -- "${HA_K8S_VERSION_MINOR:-v1.36}" <<'EOS'
set -euo pipefail
version_minor="$1"

export DEBIAN_FRONTEND=noninteractive

swapoff -a || true
sed -ri '/\sswap\s/s/^/#/' /etc/fstab || true

cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null || true

apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
systemctl enable --now containerd
systemctl restart containerd

mkdir -p -m 755 /etc/apt/keyrings
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${version_minor}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${version_minor}/deb/ /
EOF
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet
EOS
}

install_local_k8s() {
  local node_name
  local ignore_preflight
  local -a init_args

  configure_k8s_node_packages_local

  if run_privileged test -f /etc/kubernetes/admin.conf && run_privileged kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/readyz >/dev/null 2>&1; then
    return
  fi

  node_name="$(hostname)"
  ignore_preflight="${HA_K8S_KUBEADM_IGNORE_PREFLIGHT:-NumCPU}"
  init_args=(
    kubeadm init
    "--pod-network-cidr=${HA_K8S_POD_CIDR:-192.168.0.0/16}"
    "--node-name=${node_name}"
  )
  if [[ -n "$ignore_preflight" ]]; then
    init_args+=("--ignore-preflight-errors=${ignore_preflight}")
  fi

  run_privileged "${init_args[@]}"
  configure_local_kubeconfig
  kubectl apply -f "${HA_K8S_CNI_MANIFEST:-https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml}"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
  kubectl taint nodes --all node-role.kubernetes.io/master- >/dev/null 2>&1 || true
}

wait_local_kubernetes() {
  local output
  local deadline=$((SECONDS + 180))

  require_tool kubectl

  while (( SECONDS < deadline )); do
    if configure_local_kubeconfig && output="$(kubectl cluster-info 2>&1)"; then
      info "ok: local Kubernetes API is reachable"
      kubectl wait --for=condition=Ready nodes --all --timeout=180s
      kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=180s
      return
    fi
    sleep 3
  done

  [[ -z "${output:-}" ]] || info "$output"
  die "local Kubernetes did not become ready"
}

write_local_handoff() {
  local nodes_file="${HA_HANDOFF_DIR}/local-kubernetes-nodes.json"
  local info_file="${HA_HANDOFF_DIR}/local-cluster.env"

  mkdir -p "$HA_HANDOFF_DIR"
  kubectl get nodes -o json >"$nodes_file"
  {
    printf 'HA_PROVIDER=%q\n' "$(current_provider)"
    printf 'HA_CLUSTER_NAME=%q\n' "${HA_CLUSTER_NAME:-hybrid-ai-private}"
    printf 'KUBECONFIG=%q\n' "$(local_kubeconfig_path)"
  } >"$info_file"
  chmod 600 "$nodes_file" "$info_file"
  info "Wrote local handoff: ${HA_HANDOFF_DIR#${HA_PROJECT_ROOT}/}"
}

run_local_provision() {
  local auto_approve="$1"

  [[ "$auto_approve" -eq 1 ]] || die "ha up local provisions this server; pass --auto-approve"

  if command -v kubectl >/dev/null 2>&1 && configure_local_kubeconfig && kubectl cluster-info >/dev/null 2>&1; then
    info "ok: local Kubernetes already exists"
  else
    info "Provisioning local Kubernetes with kubeadm."
    install_local_k8s
  fi

  wait_local_kubernetes
  write_local_handoff
}

lxd_container_name() {
  printf '%s\n' "${HA_LXD_CONTAINER:-ha-k8s}"
}

lxd_container_ip() {
  local name="$1"
  lxc list "$name" -c 4 --format csv | awk -F'[ ()]' '
    /eth0/ {
      gsub(/"/, "", $1)
      print $1
      exit
    }
  '
}

ensure_lxd_initialized() {
  require_tool lxc

  if ! lxc profile show default >/dev/null 2>&1; then
    lxd init --auto
    return
  fi

  if ! lxc profile show default | grep -q 'pool: default'; then
    lxd init --auto
  fi
}

ensure_lxd_container() {
  local name="$1"
  local raw_lxc

  raw_lxc=$'lxc.apparmor.profile=unconfined\nlxc.cap.drop=\nlxc.mount.auto=proc:rw sys:rw cgroup:rw'

  ensure_lxd_initialized

  if ! lxc info "$name" >/dev/null 2>&1; then
    lxc init "${HA_LXD_IMAGE:-ubuntu:24.04}" "$name" \
      -c security.nesting=true \
      -c security.privileged=true \
      -c raw.lxc="$raw_lxc"
    lxc config device add "$name" kmsg unix-char source=/dev/kmsg path=/dev/kmsg
    lxc start "$name" 2>/dev/null || true
  else
    lxc config set "$name" security.nesting true
    lxc config set "$name" security.privileged true
    lxc config set "$name" raw.lxc "$raw_lxc"
    lxc config device add "$name" kmsg unix-char source=/dev/kmsg path=/dev/kmsg >/dev/null 2>&1 || true
    if ! lxc info "$name" | grep -q '^Status: RUNNING'; then
      lxc start "$name" 2>/dev/null || true
    fi
  fi

  lxc exec "$name" -- cloud-init status --wait >/dev/null 2>&1 || true
}

install_lxd_k8s() {
  local name="$1"
  local version_minor="${HA_K8S_VERSION_MINOR:-v1.36}"
  local pod_cidr="${HA_K8S_POD_CIDR:-192.168.0.0/16}"
  local cni_manifest="${HA_K8S_CNI_MANIFEST:-https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml}"
  local ignore_preflight="${HA_K8S_KUBEADM_IGNORE_PREFLIGHT:-NumCPU}"

  lxc exec "$name" -- bash -s -- "$version_minor" "$pod_cidr" "$cni_manifest" "$ignore_preflight" <<'EOS'
set -euo pipefail
version_minor="$1"
pod_cidr="$2"
cni_manifest="$3"
ignore_preflight="$4"

if [[ -f /etc/kubernetes/admin.conf ]] && kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw=/readyz >/dev/null 2>&1; then
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

swapoff -a || true
sed -ri '/\sswap\s/s/^/#/' /etc/fstab || true

cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null || true

apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
systemctl enable --now containerd
systemctl restart containerd

mkdir -p -m 755 /etc/apt/keyrings
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${version_minor}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${version_minor}/deb/ /
EOF
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet

if [[ -f /etc/kubernetes/kubelet.conf && ! -f /etc/kubernetes/admin.conf ]]; then
  kubeadm reset -f || true
fi

args=(kubeadm init "--pod-network-cidr=${pod_cidr}" --node-name "$HOSTNAME")
if [[ -n "$ignore_preflight" ]]; then
  args+=("--ignore-preflight-errors=${ignore_preflight}")
fi
"${args[@]}"

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config
kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f "$cni_manifest"
kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/master- >/dev/null 2>&1 || true
EOS
}

wait_lxd_kubernetes() {
  local name="$1"
  local count
  local deadline=$((SECONDS + 240))

  while (( SECONDS < deadline )); do
    count="$(lxc exec "$name" -- sh -lc 'kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes --no-headers 2>/dev/null | wc -l' || printf '0')"
    if [[ "$count" -gt 0 ]]; then
      lxc exec "$name" -- sh -lc 'kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready nodes --all --timeout=180s'
      lxc exec "$name" -- sh -lc 'kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready pods --all -n kube-system --timeout=180s'
      return
    fi
    sleep 3
  done

  lxc exec "$name" -- journalctl -u kubelet --no-pager -n 120 || true
  lxc exec "$name" -- journalctl -u containerd --no-pager -n 120 || true
  die "LXD Kubernetes did not become ready"
}

configure_lxd_kubeconfig() {
  local name="$1"
  local ip
  local kubeconfig

  ip="$(lxd_container_ip "$name")"
  [[ -n "$ip" ]] || die "could not resolve LXD container IP for $name"

  kubeconfig="$(local_kubeconfig_path)"
  mkdir -p "$(dirname "$kubeconfig")"
  lxc file pull "${name}/etc/kubernetes/admin.conf" "$kubeconfig"
  sed -i "s#server: https://.*#server: https://${ip}:6443#" "$kubeconfig"
  chmod 600 "$kubeconfig"
  export KUBECONFIG="$kubeconfig"
}

write_lxd_handoff() {
  local name="$1"
  local nodes_file="${HA_HANDOFF_DIR}/lxd-kubernetes-nodes.json"
  local info_file="${HA_HANDOFF_DIR}/lxd-cluster.env"

  mkdir -p "$HA_HANDOFF_DIR"
  KUBECONFIG="$(local_kubeconfig_path)" kubectl get nodes -o json >"$nodes_file"
  {
    printf 'HA_PROVIDER=%q\n' "lxd"
    printf 'HA_LXD_CONTAINER=%q\n' "$name"
    printf 'HA_CLUSTER_NAME=%q\n' "${HA_CLUSTER_NAME:-hybrid-ai-private}"
    printf 'KUBECONFIG=%q\n' "$(local_kubeconfig_path)"
  } >"$info_file"
  chmod 600 "$nodes_file" "$info_file"
  info "Wrote LXD handoff: ${HA_HANDOFF_DIR#${HA_PROJECT_ROOT}/}"
}

run_lxd_provision() {
  local auto_approve="$1"
  local name

  [[ "$auto_approve" -eq 1 ]] || die "ha up lxd provisions an LXD Kubernetes container; pass --auto-approve"

  name="$(lxd_container_name)"
  info "Provisioning Kubernetes in LXD container: ${name}"
  ensure_lxd_container "$name"
  install_lxd_k8s "$name"
  wait_lxd_kubernetes "$name"
  configure_lxd_kubeconfig "$name"
  write_lxd_handoff "$name"
}

openstack_lxd_container_name() {
  printf '%s\n' "${HA_OPENSTACK_CONTAINER:-ha-openstack}"
}

ensure_openstack_lxd_container() {
  local name="$1"
  local raw_lxc
  local kernel_modules_source

  raw_lxc=$'lxc.apparmor.profile=unconfined\nlxc.cap.drop=\nlxc.mount.auto=proc:rw sys:rw cgroup:rw'
  kernel_modules_source="$(readlink -f /lib/modules)"

  ensure_lxd_initialized

  if ! lxc info "$name" >/dev/null 2>&1; then
    lxc init "${HA_OPENSTACK_LXD_IMAGE:-ubuntu:24.04}" "$name" \
      -c security.nesting=true \
      -c security.privileged=true \
      -c raw.lxc="$raw_lxc"
    lxc config device add "$name" kmsg unix-char source=/dev/kmsg path=/dev/kmsg >/dev/null 2>&1 || true
    lxc config device remove "$name" host-kernel-modules >/dev/null 2>&1 || true
    lxc config device add "$name" host-kernel-modules disk source="$kernel_modules_source" path=/usr/lib/modules readonly=true >/dev/null 2>&1 || true
    if [[ -e /dev/kvm ]]; then
      lxc config device add "$name" kvm unix-char source=/dev/kvm path=/dev/kvm >/dev/null 2>&1 || true
    fi
    lxc start "$name" 2>/dev/null || true
  else
    lxc config set "$name" security.nesting true
    lxc config set "$name" security.privileged true
    lxc config set "$name" raw.lxc "$raw_lxc"
    lxc config device add "$name" kmsg unix-char source=/dev/kmsg path=/dev/kmsg >/dev/null 2>&1 || true
    lxc config device remove "$name" host-kernel-modules >/dev/null 2>&1 || true
    lxc config device add "$name" host-kernel-modules disk source="$kernel_modules_source" path=/usr/lib/modules readonly=true >/dev/null 2>&1 || true
    if [[ -e /dev/kvm ]]; then
      lxc config device add "$name" kvm unix-char source=/dev/kvm path=/dev/kvm >/dev/null 2>&1 || true
    fi
    if ! lxc info "$name" | grep -q '^Status: RUNNING'; then
      lxc start "$name" 2>/dev/null || true
    fi
  fi

  lxc exec "$name" -- cloud-init status --wait >/dev/null 2>&1 || true
}

ensure_openstack_lxd_kernel_modules() {
  local name="$1"

  lxc exec "$name" -- bash -lc '
    set -euo pipefail
    modprobe openvswitch
    modprobe vport-geneve
    modprobe vport-vxlan
  ' || die "failed to load Open vSwitch kernel modules in ${name}; make sure linux-modules-extra-$(uname -r) is installed on the host"
}

openstack_persistent_path() {
  local path="$1"
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$HA_PROJECT_ROOT" "$path"
  fi
}

configure_openstack_persistent_mount() {
  local name="$1"
  local device="$2"
  local host_dir="$3"
  local container_dir="$4"
  local container_parent source path

  [[ "${HA_OPENSTACK_PERSISTENT_STORAGE:-true}" == "true" ]] || return 0

  mkdir -p "$host_dir"
  container_parent="${container_dir%/*}"
  lxc exec "$name" -- mkdir -p "$container_parent" >/dev/null

  source="$(lxc config device get "$name" "$device" source 2>/dev/null || true)"
  path="$(lxc config device get "$name" "$device" path 2>/dev/null || true)"
  if [[ -n "$source" || -n "$path" ]]; then
    if [[ "$source" != "$host_dir" || "$path" != "$container_dir" ]]; then
      lxc config device remove "$name" "$device" >/dev/null
      source=""
      path=""
    fi
  fi
  if [[ -z "$source" && -z "$path" ]]; then
    lxc config device add "$name" "$device" disk \
      source="$host_dir" \
      path="$container_dir" >/dev/null
  fi

  lxc exec "$name" -- bash -s -- "$container_dir" <<'EOS'
set -euo pipefail
container_dir="$1"
container_parent="${container_dir%/*}"
mkdir -p "$container_dir"
if id stack >/dev/null 2>&1; then
  mkdir -p /opt/stack/data "$container_parent"
  chown stack:stack /opt/stack /opt/stack/data "$container_parent"
  chown -R stack:stack "$container_dir"
fi
chmod 0755 "$container_dir"
EOS
}

configure_openstack_persistent_storage() {
  local name="$1"
  local persistent_dir glance_dir nova_dir

  [[ "${HA_OPENSTACK_PERSISTENT_STORAGE:-true}" == "true" ]] || return 0

  persistent_dir="$(openstack_persistent_path "${HA_OPENSTACK_PERSISTENT_DIR:-.ha/openstack/persistent}")"
  glance_dir="$(openstack_persistent_path "${HA_OPENSTACK_GLANCE_STORE_DIR:-${persistent_dir}/glance-images}")"
  nova_dir="$(openstack_persistent_path "${HA_OPENSTACK_NOVA_INSTANCES_DIR:-${persistent_dir}/nova-instances}")"

  info "Configuring persistent OpenStack storage mounts"
  configure_openstack_persistent_mount "$name" hybrid-ai-glance-store "$glance_dir" /opt/stack/data/glance/images
  configure_openstack_persistent_mount "$name" hybrid-ai-nova-instances "$nova_dir" /opt/stack/data/nova/instances
}

write_devstack_local_conf() {
  local name="$1"
  local host_ip="$2"
  local password="$3"
  local libvirt_type="${HA_DEVSTACK_LIBVIRT_TYPE:-auto}"

  lxc exec "$name" -- bash -s -- "$host_ip" "$password" "$libvirt_type" <<'EOS'
set -euo pipefail
host_ip="$1"
password="$2"
requested_libvirt_type="$3"
if [[ "$requested_libvirt_type" == "auto" ]]; then
  if [[ -e /dev/kvm ]]; then
    libvirt_type="kvm"
  else
    libvirt_type="qemu"
  fi
else
  libvirt_type="$requested_libvirt_type"
fi
printf 'DevStack libvirt type: %s\n' "$libvirt_type"
install -d -o stack -g stack /opt/stack/devstack
cat >/opt/stack/devstack/local.conf <<EOF
[[local|localrc]]
ADMIN_PASSWORD=${password}
DATABASE_PASSWORD=${password}
RABBIT_PASSWORD=${password}
SERVICE_PASSWORD=${password}
HOST_IP=${host_ip}
SERVICE_HOST=${host_ip}
LOGFILE=/opt/stack/logs/stack.sh.log
LOG_COLOR=False
VERBOSE=True
LIBVIRT_TYPE=${libvirt_type}
ENABLE_VOLUME_BACKING_FILE=True
disable_service tempest

[[post-config|\$NOVA_CONF]]
[DEFAULT]
instances_path = /opt/stack/data/nova/instances
force_raw_images = False

[neutron]
project_domain_name = Default

[[post-config|/etc/nova/nova-cpu.conf]]
[DEFAULT]
instances_path = /opt/stack/data/nova/instances
force_raw_images = False

[neutron]
project_domain_name = Default

[[post-config|\$GLANCE_API_CONF]]
[glance_store]
filesystem_store_datadir = /opt/stack/data/glance/images
EOF
chown stack:stack /opt/stack/devstack/local.conf
chmod 600 /opt/stack/devstack/local.conf
EOS
}

validate_devstack_password() {
  local password="$1"
  local source_name="$2"

  [[ -n "$password" ]] || die "${source_name} is required for local DevStack"
  [[ "${#password}" -ge 8 ]] || die "${source_name} must be at least 8 characters"
  [[ "${#password}" -le 128 ]] || die "${source_name} must be 128 characters or fewer"
  [[ ! "$password" =~ [[:space:]] ]] || die "${source_name} must not contain whitespace"
  if [[ ! "$password" =~ ^[A-Za-z0-9._~!-]+$ ]]; then
    die "${source_name} contains characters outside the DevStack-safe set: letters, digits, dot, underscore, hyphen, tilde, exclamation"
  fi
}

devstack_openstack_ready() {
  local name="$1"

  lxc exec "$name" -- sudo -u stack -H bash -lc '
    set -e
    cd /opt/stack/devstack
    [ -f openrc ] || exit 1
    source openrc admin admin
    openstack token issue -f value -c id >/dev/null
    openstack compute service list -f value >/dev/null
    openstack network list -f value >/dev/null
    openstack image list -f value >/dev/null
    openstack volume service list -f value >/dev/null
  ' >/dev/null 2>&1
}

install_lxd_devstack() {
  local name="$1"
  local password="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
  local branch="${HA_DEVSTACK_BRANCH:-master}"
  local host_ip

  validate_devstack_password "$password" "HA_DEVSTACK_PASSWORD"

  host_ip="$(lxd_container_ip "$name")"
  [[ -n "$host_ip" ]] || die "could not resolve LXD container IP for $name"

  if devstack_openstack_ready "$name"; then
    info "ok: local OpenStack already reachable in ${name}"
    return
  fi

  info "Installing local OpenStack control plane with DevStack in LXD: ${name}"
  lxc exec "$name" -- bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git sudo curl ca-certificates iproute2 net-tools kmod python3-openstackclient
    if ! id stack >/dev/null 2>&1; then
      useradd -s /bin/bash -d /opt/stack -m stack
    fi
    chmod +x /opt/stack
    printf "stack ALL=(ALL) NOPASSWD: ALL\n" >/etc/sudoers.d/stack
    chmod 440 /etc/sudoers.d/stack
    chown -R stack:stack /opt/stack
  '
  configure_openstack_persistent_storage "$name"

  if ! lxc exec "$name" -- test -d /opt/stack/devstack/.git; then
    lxc exec "$name" -- sudo -u stack -H bash -lc \
      "git clone --depth=1 --branch '${branch}' https://opendev.org/openstack/devstack /opt/stack/devstack"
  fi

  write_devstack_local_conf "$name" "$host_ip" "$password"
  ensure_openstack_lxd_kernel_modules "$name"
  lxc exec "$name" -- sudo -u stack -H bash -lc 'cd /opt/stack/devstack && ./stack.sh'
}

write_openstack_local_handoff() {
  local name="$1"
  local password="${HA_DEVSTACK_PASSWORD:-hybrid-ai-devstack}"
  local ip
  local dir="${HA_PROJECT_ROOT}/.ha/openstack-local"

  ip="$(lxd_container_ip "$name")"
  [[ -n "$ip" ]] || die "could not resolve LXD container IP for $name"

  mkdir -p "$dir" "$HA_HANDOFF_DIR"
  {
    printf 'export OS_AUTH_URL=%q\n' "http://${ip}/identity/v3"
    printf 'export OS_PROJECT_NAME=%q\n' "admin"
    printf 'export OS_USERNAME=%q\n' "admin"
    printf 'export OS_PASSWORD=%q\n' "$password"
    printf 'export OS_USER_DOMAIN_NAME=%q\n' "Default"
    printf 'export OS_PROJECT_DOMAIN_NAME=%q\n' "Default"
    printf 'export OS_REGION_NAME=%q\n' "RegionOne"
    printf 'export OS_IDENTITY_API_VERSION=%q\n' "3"
  } >"${dir}/openrc.sh"
  chmod 600 "${dir}/openrc.sh"

  {
    printf 'HA_OPENSTACK_CONTAINER=%q\n' "$name"
    printf 'OS_AUTH_URL=%q\n' "http://${ip}/identity/v3"
    printf 'OS_PROJECT_NAME=%q\n' "admin"
    printf 'OS_USERNAME=%q\n' "admin"
    printf 'OS_REGION_NAME=%q\n' "RegionOne"
    printf 'OPENRC=%q\n' "${dir}/openrc.sh"
  } >"${HA_HANDOFF_DIR}/local-openstack.env"
  chmod 600 "${HA_HANDOFF_DIR}/local-openstack.env"
  info "Wrote local OpenStack handoff: ${HA_HANDOFF_DIR#${HA_PROJECT_ROOT}/local-openstack.env}"
  info "Source credentials with: source ${dir#${HA_PROJECT_ROOT}/}/openrc.sh"
}

run_openstack_local_provision() {
  local auto_approve="$1"
  local name

  [[ "$auto_approve" -eq 1 ]] || die "ha up openstack-local installs OpenStack locally; pass --auto-approve"

  name="$(openstack_lxd_container_name)"
  ensure_openstack_lxd_container "$name"
  install_lxd_devstack "$name"
  if devstack_openstack_ready "$name"; then
    info "ok: local OpenStack API is reachable"
  else
    lxc exec "$name" -- bash -lc 'tail -n 160 /opt/stack/logs/stack.sh.log 2>/dev/null || true'
    die "local OpenStack did not become ready"
  fi
  write_openstack_local_handoff "$name"
}

run_tests() {
  local terraform_init=0
  local integration=0

  HA_TEST_FAILED=0
  HA_TEST_SKIPPED=0
  HA_TEST_STRICT=0
  HA_PROMPT_PASSWORD=0

  load_env_file

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        HA_TEST_STRICT=1
        shift
        ;;
      --terraform-init)
        terraform_init=1
        shift
        ;;
      --integration)
        integration=1
        terraform_init=1
        shift
        ;;
      *)
        parse_openstack_option "$@"
        case "$HA_OPENSTACK_OPTION_CONSUMED" in
          1)
            shift
            ;;
          2)
            shift 2
            ;;
          *)
            die "unknown test option: $1"
            ;;
        esac
        ;;
    esac
  done

  info "Running local tests for ${HA_PROJECT_NAME}"

  test_project_layout
  test_bash_syntax
  test_caddy_config
  test_yaml_syntax
  test_kustomization_references
  test_terraform_static "$terraform_init"
  test_kustomize_render

  if [[ "$integration" -eq 1 ]]; then
    info "Running integration checks for provider $(current_provider)."
    case "$(current_provider)" in
      local|server|lxd)
        test_kubernetes_cluster 0 || true
        ;;
      openstack)
        test_terraform_plan || true
        test_kubernetes_cluster 0 || true
        ;;
      *)
        test_fail "unknown provider $(current_provider)"
        ;;
    esac
  fi

  if [[ "$HA_TEST_FAILED" -eq 0 ]]; then
    if [[ "$HA_TEST_SKIPPED" -gt 0 ]]; then
      info "Local tests passed with ${HA_TEST_SKIPPED} skipped check(s)."
    else
      info "Local tests passed."
    fi
    return
  fi

  die "local tests failed"
}

run_private_cloud_ci() {
  local script="${HA_PROJECT_ROOT}/private/ci/private-cloud-ci.sh"

  if [[ -x "$script" ]]; then
    "$script" "$@"
    return
  fi

  run_tests --terraform-init "$@"
}

run_private_cloud_apply() {
  local script="${HA_PROJECT_ROOT}/private/ci/private-cloud-apply.sh"

  [[ -x "$script" ]] || die "missing executable private cloud apply script: ${script#${HA_PROJECT_ROOT}/}"
  "$script" "$@"
}

run_private_cloud_destroy() {
  local script="${HA_PROJECT_ROOT}/private/ci/private-cloud-destroy.sh"

  [[ -x "$script" ]] || die "missing executable private cloud destroy script: ${script#${HA_PROJECT_ROOT}/}"
  "$script" "$@"
}

require_openstack_env() {
  if ! test_integration_env; then
    cat >&2 <<'EOF'
ha: missing or placeholder OpenStack/Terraform environment.

Fill the local env files, then retry:
  .env:
    OS_AUTH_URL
    OS_PROJECT_NAME or OS_PROJECT_ID
    OS_USER_DOMAIN_NAME and OS_PROJECT_DOMAIN_NAME, usually Default

  .env.secret:
    OS_USERNAME
    OS_PASSWORD

OS_AUTH_URL is not created by this repository. It is the Keystone/Identity
endpoint of the existing OpenStack control plane.

Default provisioning does not need these values. Use auto/local/LXD mode instead:
  HA_PROVIDER=auto ha up all --auto-approve

Use `ha env init` to create the files and `ha env check` to validate them.
EOF
    exit 1
  fi
}

terraform_init_for_apply() {
  if [[ -n "${TF_BACKEND_CONFIG:-}" ]]; then
    printf 'terraform {\n  backend "%s" {}\n}\n' "${TF_BACKEND_TYPE:-s3}" >"${HA_OPENSTACK_DIR}/backend.generated.tf"
    printf "%s" "$TF_BACKEND_CONFIG" >"${HA_OPENSTACK_DIR}/backend.hcl"
    terraform -chdir="$HA_OPENSTACK_DIR" init -reconfigure -backend-config=backend.hcl
  else
    terraform -chdir="$HA_OPENSTACK_DIR" init -backend=false -reconfigure
  fi
}

run_openstack_up() {
  local auto_approve="$1"
  local output
  local plan_file

  [[ "$auto_approve" -eq 1 ]] || die "ha up openstack creates resources; pass --auto-approve"

  require_tool terraform
  ensure_openstack_ssh_public_key
  require_openstack_env

  info "Applying OpenStack Terraform foundation."

  if output="$(terraform_init_for_apply 2>&1)"; then
    info "ok: terraform init"
  else
    [[ -z "$output" ]] || info "$output"
    die "terraform init failed"
  fi

  if output="$(terraform -chdir="$HA_OPENSTACK_DIR" fmt -check -recursive 2>&1)"; then
    info "ok: terraform fmt"
  else
    [[ -z "$output" ]] || info "$output"
    die "terraform fmt failed"
  fi

  if output="$(terraform -chdir="$HA_OPENSTACK_DIR" validate 2>&1)"; then
    info "ok: terraform validate"
  else
    [[ -z "$output" ]] || info "$output"
    die "terraform validate failed"
  fi

  plan_file="$(mktemp "${HA_OPENSTACK_DIR}/private-cloud.XXXXXX.tfplan")"
  if output="$(terraform -chdir="$HA_OPENSTACK_DIR" plan -out="$plan_file" 2>&1)"; then
    info "ok: terraform plan"
  else
    rm -f "$plan_file"
    [[ -z "$output" ]] || info "$output"
    die "terraform plan failed"
  fi

  if output="$(terraform -chdir="$HA_OPENSTACK_DIR" apply -auto-approve "$plan_file" 2>&1)"; then
    info "ok: terraform apply"
  else
    rm -f "$plan_file"
    [[ -z "$output" ]] || info "$output"
    die "terraform apply failed"
  fi

  rm -f "$plan_file"
  write_openstack_handoff
}

run_openstack_kubernetes_bootstrap() {
  local auto_approve="$1"
  local bootstrap_script="${HA_OPENSTACK_BOOTSTRAP_DIR}/bootstrap-k8s.sh"

  [[ "$auto_approve" -eq 1 ]] || die "ha up openstack-kubernetes bootstraps nodes over SSH; pass --auto-approve"
  [[ -x "$bootstrap_script" ]] || die "bootstrap script not executable: ${bootstrap_script#${HA_PROJECT_ROOT}/}"

  ensure_openstack_ssh_public_key
  "$bootstrap_script"
}

run_kubernetes_up() {
  local target="$1"

  require_tool kubectl
  case "$(current_provider)" in
    local|server)
      configure_local_kubeconfig || die "local kubeconfig not found; run ha up local --auto-approve first"
      ;;
    lxd)
      [[ -f "$(local_kubeconfig_path)" ]] || run_lxd_provision 1
      KUBECONFIG="$(local_kubeconfig_path)"
      export KUBECONFIG
      ;;
    *)
      configure_kubeconfig_from_env || die "failed to decode PRIVATE_CLOUD_KUBECONFIG_B64"
      if [[ "$HA_KUBECONFIG_DECODED" -eq 1 ]]; then
        info "Decoded PRIVATE_CLOUD_KUBECONFIG_B64"
      fi
      [[ -n "${KUBECONFIG:-}" ]] || die "OpenStack kubeconfig not found; run ha up openstack-kubernetes --auto-approve or set KUBECONFIG"
      ;;
  esac

  info "Applying Kubernetes manifests: ${target}"
  run_k8s apply "$target"
}

run_up() {
  local target="all"
  local auto_approve=0
  HA_PROMPT_PASSWORD=0

  if [[ $# -gt 0 && "$1" != --* ]]; then
    target="$1"
    shift
  fi

  load_env_file

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto-approve)
        auto_approve=1
        shift
        ;;
      *)
        parse_openstack_option "$@"
        case "$HA_OPENSTACK_OPTION_CONSUMED" in
          1)
            shift
            ;;
          2)
            shift 2
            ;;
          *)
            die "unknown up option: $1"
            ;;
        esac
        ;;
    esac
  done

  case "$target" in
    local|server)
      run_local_provision "$auto_approve"
      ;;
    lxd)
      run_lxd_provision "$auto_approve"
      ;;
    openstack-local|devstack)
      run_openstack_local_provision "$auto_approve"
      ;;
    openstack|terraform)
      run_openstack_up "$auto_approve"
      ;;
    openstack-kubernetes|openstack-k8s)
      run_openstack_kubernetes_bootstrap "$auto_approve"
      ;;
    kubernetes|foundation|base|storage|gpu|gpu-worker)
      run_kubernetes_up "$target"
      ;;
    k8s)
      run_kubernetes_up all
      ;;
    all)
      case "$(current_provider)" in
        local|server)
          run_local_provision "$auto_approve"
          run_kubernetes_up kubernetes
          if [[ "${HA_APPLY_STORAGE:-0}" == "1" ]]; then
            run_kubernetes_up storage
          fi
          if [[ "${HA_APPLY_GPU:-0}" == "1" ]]; then
            run_kubernetes_up gpu
          fi
          ;;
        lxd)
          run_lxd_provision "$auto_approve"
          run_kubernetes_up kubernetes
          if [[ "${HA_APPLY_STORAGE:-0}" == "1" ]]; then
            run_kubernetes_up storage
          fi
          if [[ "${HA_APPLY_GPU:-0}" == "1" ]]; then
            run_kubernetes_up gpu
          fi
          ;;
        openstack)
          run_openstack_up "$auto_approve"
          if [[ "${HA_OPENSTACK_BOOTSTRAP_K8S:-0}" == "1" ]]; then
            run_openstack_kubernetes_bootstrap "$auto_approve"
            run_kubernetes_up kubernetes
            if [[ "${HA_APPLY_STORAGE:-0}" == "1" ]]; then
              run_kubernetes_up storage
            fi
            if [[ "${HA_APPLY_GPU:-0}" == "1" ]]; then
              run_kubernetes_up gpu
            fi
          else
            info "OpenStack resources applied. Set HA_OPENSTACK_BOOTSTRAP_K8S=1 or run ha up openstack-kubernetes --auto-approve to bootstrap Kubernetes."
          fi
          ;;
        *)
          die "unknown HA_PROVIDER=$(current_provider)"
          ;;
      esac
      ;;
    *)
      die "unknown up target: ${target}"
      ;;
  esac
}

git_status() {
  git -C "$HA_PROJECT_ROOT" status --short --branch
}

run_terraform() {
  [[ $# -gt 0 ]] || die "missing terraform arguments"
  require_tool terraform
  terraform -chdir="$HA_OPENSTACK_DIR" "$@"
}

k8s_paths() {
  local target="${1:-kubernetes}"
  case "$target" in
    kubernetes|foundation|base)
      printf '%s\n' "${HA_PROJECT_ROOT}/private/kubernetes"
      ;;
    storage)
      printf '%s\n' "${HA_PROJECT_ROOT}/private/storage"
      ;;
    gpu|gpu-worker)
      printf '%s\n' "${HA_PROJECT_ROOT}/private/gpu-worker"
      ;;
    all)
      printf '%s\n' \
        "${HA_PROJECT_ROOT}/private/kubernetes" \
        "${HA_PROJECT_ROOT}/private/storage" \
        "${HA_PROJECT_ROOT}/private/gpu-worker"
      ;;
    *)
      die "unknown k8s target: ${target}"
      ;;
  esac
}

run_k8s() {
  local action="${1:-}"
  local target="${2:-kubernetes}"
  [[ -n "$action" ]] || die "missing k8s action"
  shift || true
  shift || true

  require_tool kubectl

  local path
  while IFS= read -r path; do
    case "$action" in
      render)
        info "# ${path#${HA_PROJECT_ROOT}/}" >&2
        kubectl kustomize "$path" "$@"
        ;;
      diff)
        kubectl diff -k "$path" "$@"
        ;;
      apply)
        kubectl apply -k "$path" "$@"
        ;;
      *)
        die "unknown k8s action: ${action}"
        ;;
    esac
  done < <(k8s_paths "$target")
}

PROD_FAILED=0
PROD_WARNED=0

prod_ok() {
  info "ok: $*"
}

prod_warn() {
  info "warn: $*"
  PROD_WARNED=$((PROD_WARNED + 1))
}

prod_fail() {
  info "fail: $*"
  PROD_FAILED=$((PROD_FAILED + 1))
}

configure_prod_kubeconfig() {
  load_env_file

  if [[ -n "${KUBECONFIG:-}" ]]; then
    return 0
  fi

  if [[ -f "$(local_kubeconfig_path)" ]]; then
    KUBECONFIG="$(local_kubeconfig_path)"
    export KUBECONFIG
    return 0
  fi

  case "$(current_provider)" in
    local|server)
      configure_local_kubeconfig
      ;;
    lxd)
      if command -v lxc >/dev/null 2>&1 && lxc info "$(lxd_container_name)" >/dev/null 2>&1; then
        configure_lxd_kubeconfig "$(lxd_container_name)"
      else
        return 1
      fi
      ;;
    *)
      configure_kubeconfig_from_env && [[ -n "${KUBECONFIG:-}" ]]
      ;;
  esac
}

kubectl_has_rows() {
  [[ -n "$("$@" --no-headers 2>/dev/null)" ]]
}

prod_check_cluster_access() {
  local output

  require_tool kubectl
  if ! configure_prod_kubeconfig; then
    prod_fail "kubeconfig not found; run ha up all --auto-approve or set KUBECONFIG"
    return
  fi

  if output="$(kubectl cluster-info 2>&1)"; then
    prod_ok "Kubernetes API reachable"
    printf '%s\n' "$output" | sed -n '1p'
  else
    [[ -z "$output" ]] || info "$output"
    prod_fail "Kubernetes API not reachable"
  fi
}

prod_check_nodes() {
  local node_count
  local min_nodes="${HA_PROD_MIN_NODES:-3}"
  local min_control_plane="${HA_PROD_MIN_CONTROL_PLANE:-3}"
  local control_plane_count
  local not_ready

  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ "$node_count" -ge "$min_nodes" ]]; then
    prod_ok "node count ${node_count} >= ${min_nodes}"
  else
    prod_fail "node count ${node_count} < ${min_nodes}"
  fi

  control_plane_count="$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ "$control_plane_count" -eq 0 ]]; then
    control_plane_count="$(kubectl get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
  fi

  if [[ "$control_plane_count" -ge "$min_control_plane" ]]; then
    prod_ok "control-plane count ${control_plane_count} >= ${min_control_plane}"
  else
    prod_fail "control-plane count ${control_plane_count} < ${min_control_plane}"
  fi

  not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" { print $1 ":" $2 }')"
  if [[ -z "$not_ready" ]]; then
    prod_ok "all nodes Ready"
  else
    prod_fail "not-ready nodes: ${not_ready}"
  fi
}

prod_check_pods_ready_for_namespace() {
  local namespace="$1"
  local label="$2"
  local output
  local bad

  output="$(kubectl get pods -n "$namespace" --field-selector=status.phase!=Succeeded --no-headers 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    prod_warn "no non-completed pods found in ${label}"
    return
  fi

  bad="$(printf '%s\n' "$output" | awk '
    {
      split($2, ready, "/")
      if ($3 != "Running" || ready[1] != ready[2]) {
        print $1 ":" $2 ":" $3
      }
    }
  ')"
  if [[ -z "$bad" ]]; then
    prod_ok "${label} pods Ready"
  else
    prod_fail "${label} pods not Ready: ${bad}"
  fi
}

prod_check_all_pods_ready() {
  local output
  local bad

  output="$(kubectl get pods -A --field-selector=status.phase!=Succeeded --no-headers 2>/dev/null || true)"
  bad="$(printf '%s\n' "$output" | awk '
    NF > 0 {
      split($3, ready, "/")
      if ($4 != "Running" || ready[1] != ready[2]) {
        print $1 "/" $2 ":" $3 ":" $4
      }
    }
  ')"
  if [[ -z "$bad" ]]; then
    prod_ok "all non-completed pods Ready"
  else
    prod_fail "pods not Ready: ${bad}"
  fi
}

prod_check_storage() {
  local default_sc

  default_sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n 1)"
  if [[ -z "$default_sc" ]]; then
    prod_fail "no default StorageClass"
    return
  fi

  if [[ "$default_sc" == "local-path" && "${HA_PROD_ALLOW_LOCAL_PATH:-0}" != "1" ]]; then
    prod_fail "default StorageClass is local-path; production needs replicated or external storage"
  else
    prod_ok "default StorageClass ${default_sc}"
  fi
}

prod_check_optional_platforms() {
  if kubectl_has_rows kubectl get ingressclass; then
    prod_ok "IngressClass exists"
  else
    prod_fail "IngressClass missing"
  fi

  if kubectl get namespace cert-manager >/dev/null 2>&1; then
    if kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=10s >/dev/null 2>&1; then
      prod_ok "cert-manager deployments Available"
    else
      prod_fail "cert-manager namespace exists but deployments are not Available"
    fi
  else
    prod_fail "cert-manager missing"
  fi

  if kubectl get namespace monitoring >/dev/null 2>&1 || kubectl get namespace cattle-monitoring-system >/dev/null 2>&1; then
    prod_ok "monitoring namespace exists"
  else
    prod_fail "monitoring stack missing"
  fi

  if kubectl get namespace velero >/dev/null 2>&1 || [[ -n "${HA_BACKUP_TARGET:-}" ]]; then
    prod_ok "backup target/controller configured"
  else
    prod_fail "backup target/controller missing"
  fi
}

prod_check_namespace_controls() {
  local ns
  local enforce

  for ns in private-infra private-storage model-build gpu-workload; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      prod_fail "namespace ${ns} missing"
      continue
    fi

    enforce="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"
    case "$enforce" in
      baseline|restricted)
        prod_ok "${ns} pod-security enforce=${enforce}"
        ;;
      *)
        prod_fail "${ns} pod-security enforce label missing"
        ;;
    esac

    if kubectl_has_rows kubectl get resourcequota -n "$ns"; then
      prod_ok "${ns} ResourceQuota exists"
    else
      prod_fail "${ns} ResourceQuota missing"
    fi

    if kubectl_has_rows kubectl get limitrange -n "$ns"; then
      prod_ok "${ns} LimitRange exists"
    else
      prod_fail "${ns} LimitRange missing"
    fi

    if kubectl_has_rows kubectl get networkpolicy -n "$ns"; then
      prod_ok "${ns} NetworkPolicy exists"
    else
      prod_fail "${ns} NetworkPolicy missing"
    fi
  done
}

run_prod_check() {
  PROD_FAILED=0
  PROD_WARNED=0

  prod_check_cluster_access
  if [[ "$PROD_FAILED" -gt 0 ]]; then
    die "production readiness check failed"
  fi

  prod_check_nodes
  prod_check_pods_ready_for_namespace kube-system kube-system
  prod_check_all_pods_ready
  prod_check_storage
  prod_check_namespace_controls
  prod_check_optional_platforms

  if [[ "$PROD_FAILED" -gt 0 ]]; then
    die "production readiness check failed with ${PROD_FAILED} failure(s), ${PROD_WARNED} warning(s)"
  fi

  if [[ "$PROD_WARNED" -gt 0 ]]; then
    info "Production readiness check passed with ${PROD_WARNED} warning(s)."
  else
    info "Production readiness check passed."
  fi
}

run_prod() {
  local action="${1:-check}"

  case "$action" in
    check)
      run_prod_check
      ;;
    *)
      die "unknown prod action: ${action}"
      ;;
  esac
}

main() {
  require_project_context

  local command="${1:-help}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    help|-h|--help)
      usage
      ;;
    install)
      install_launcher "$@"
      ;;
    uninstall)
      uninstall_launcher "$@"
      ;;
    doctor)
      doctor
      ;;
    ci)
      run_private_cloud_ci "$@"
      ;;
    explain|guide)
      explain
      ;;
    completion)
      completion_script "$@"
      ;;
    test)
      run_tests "$@"
      ;;
    apply)
      run_private_cloud_apply "$@"
      ;;
    destroy)
      run_private_cloud_destroy "$@"
      ;;
    up)
      run_up "$@"
      ;;
    prod|production)
      run_prod "$@"
      ;;
    env)
      run_env "$@"
      ;;
    proxy|caddy)
      run_proxy "$@"
      ;;
    status)
      git_status
      ;;
    tf|terraform)
      run_terraform "$@"
      ;;
    k8s|kubectl)
      run_k8s "$@"
      ;;
    path)
      info "$HA_PROJECT_ROOT"
      ;;
    *)
      usage >&2
      die "unknown command: ${command}"
      ;;
  esac
}

main "$@"
