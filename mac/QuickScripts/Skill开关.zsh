#!/bin/zsh

set -u

SOURCE="/Users/sunkanwei/Library/Application Support/Blender/5.1/extensions/user_default/NexusUIweb/skill/nexus-ui-web"
TARGET="/Users/sunkanwei/.agents/skills/nexus-ui-web"
TARGET_PARENT="${TARGET:h}"

finish() {
    local exit_code="$1"
    local message="$2"
    echo "$message"
    exit "$exit_code"
}

if [[ ! -d "$SOURCE" || ! -f "$SOURCE/SKILL.md" ]]; then
    echo "来源位置：$SOURCE"
    finish 1 "操作失败：找不到完整的 Nexus UI Web Skill。"
fi

if [[ -L "$TARGET" ]]; then
    source_real="${SOURCE:A}"
    target_real="${TARGET:A}"
    if [[ "$target_real" != "$source_real" ]]; then
        echo "当前指向：$(readlink "$TARGET")"
        finish 1 "操作已停止：Codex 中的同名映射指向其他位置，本脚本不会覆盖或删除它。"
    fi

    if ! /bin/unlink "$TARGET"; then
        finish 1 "操作失败：无法取消当前映射。"
    fi

    finish 0 "已停用：源文件没有被删除；重新启动 Codex 或新建任务后确认结果。"
fi

if [[ -e "$TARGET" ]]; then
    finish 1 "操作已停止：Codex 中已存在同名的真实文件或目录，本脚本不会覆盖或删除它。"
fi

if ! /bin/mkdir -p "$TARGET_PARENT"; then
    finish 1 "操作失败：无法创建 Codex Skill 目录。"
fi

if ! /bin/ln -s "$SOURCE" "$TARGET"; then
    finish 1 "操作失败：无法建立 Skill 映射。"
fi

finish 0 "已启用：重新启动 Codex 或新建任务后确认结果。"
