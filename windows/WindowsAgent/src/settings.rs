use std::{
    path::PathBuf,
    rc::Rc,
    sync::atomic::{AtomicBool, Ordering},
    thread,
};

use native_windows_gui as nwg;

use crate::{
    config::{ConfigStore, ModelProfile, WorkspaceConfig, validate_id},
    credentials,
    error::{AgentError, AgentResult},
    model::ModelClient,
};

static OPEN: AtomicBool = AtomicBool::new(false);

pub fn open(store: ConfigStore) {
    if OPEN.swap(true, Ordering::SeqCst) {
        return;
    }
    thread::spawn(move || {
        let result = run(store);
        if let Err(error) = result {
            let _ = nwg::init();
            nwg::simple_message("Windows Agent 设置", &error.to_string());
        }
        OPEN.store(false, Ordering::SeqCst);
    });
}

struct SettingsUi {
    window: nwg::Window,
    model_list: nwg::ListBox<String>,
    model_id: nwg::TextInput,
    model_name: nwg::TextInput,
    base_url: nwg::TextInput,
    model_name_api: nwg::TextInput,
    credential: nwg::TextInput,
    secret: nwg::TextInput,
    supports_images: nwg::CheckBox,
    timeout: nwg::TextInput,
    input_cost: nwg::TextInput,
    output_cost: nwg::TextInput,
    new_model: nwg::Button,
    save_model: nwg::Button,
    delete_model: nwg::Button,
    select_model: nwg::Button,
    test_model: nwg::Button,
    project_list: nwg::ListBox<String>,
    project_id: nwg::TextInput,
    project_name: nwg::TextInput,
    project_path: nwg::TextInput,
    new_project: nwg::Button,
    save_project: nwg::Button,
    delete_project: nwg::Button,
    port: nwg::TextInput,
    save_service: nwg::Button,
}

fn run(store: ConfigStore) -> AgentResult<()> {
    nwg::init().map_err(gui_error)?;
    nwg::Font::set_global_family("Microsoft YaHei UI").map_err(gui_error)?;

    let mut ui = SettingsUi {
        window: Default::default(),
        model_list: Default::default(),
        model_id: Default::default(),
        model_name: Default::default(),
        base_url: Default::default(),
        model_name_api: Default::default(),
        credential: Default::default(),
        secret: Default::default(),
        supports_images: Default::default(),
        timeout: Default::default(),
        input_cost: Default::default(),
        output_cost: Default::default(),
        new_model: Default::default(),
        save_model: Default::default(),
        delete_model: Default::default(),
        select_model: Default::default(),
        test_model: Default::default(),
        project_list: Default::default(),
        project_id: Default::default(),
        project_name: Default::default(),
        project_path: Default::default(),
        new_project: Default::default(),
        save_project: Default::default(),
        delete_project: Default::default(),
        port: Default::default(),
        save_service: Default::default(),
    };

    nwg::Window::builder()
        .size((940, 720))
        .position((220, 100))
        .title("Windows Agent 设置")
        .build(&mut ui.window)
        .map_err(gui_error)?;

    label(
        &ui.window,
        "模型配置（当前模型由 Windows 管理）",
        (20, 14),
        (500, 24),
    )?;
    nwg::ListBox::builder()
        .parent(&ui.window)
        .position((20, 42))
        .size((260, 330))
        .build(&mut ui.model_list)
        .map_err(gui_error)?;
    field(&ui.window, "编号", &mut ui.model_id, 300, 42)?;
    field(&ui.window, "显示名称", &mut ui.model_name, 300, 82)?;
    field(&ui.window, "API 地址", &mut ui.base_url, 300, 122)?;
    field(&ui.window, "模型标识", &mut ui.model_name_api, 300, 162)?;
    field(&ui.window, "凭据名称", &mut ui.credential, 300, 202)?;
    field(
        &ui.window,
        "API 密钥（留空则不更改）",
        &mut ui.secret,
        300,
        242,
    )?;
    ui.secret.set_password_char(Some('●'));
    nwg::CheckBox::builder()
        .text("支持图片输入")
        .parent(&ui.window)
        .position((300, 282))
        .size((160, 25))
        .build(&mut ui.supports_images)
        .map_err(gui_error)?;
    small_field(&ui.window, "超时（秒）", &mut ui.timeout, 480, 282)?;
    small_field(&ui.window, "输入单价/百万", &mut ui.input_cost, 700, 282)?;
    small_field(&ui.window, "输出单价/百万", &mut ui.output_cost, 700, 322)?;
    button(&ui.window, "新建", &mut ui.new_model, 300, 347, 90)?;
    button(&ui.window, "保存", &mut ui.save_model, 400, 347, 90)?;
    button(&ui.window, "设为当前", &mut ui.select_model, 500, 347, 100)?;
    button(&ui.window, "测试连接", &mut ui.test_model, 610, 347, 100)?;
    button(&ui.window, "删除", &mut ui.delete_model, 720, 347, 90)?;

    label(&ui.window, "登记代码项目", (20, 400), (300, 24))?;
    nwg::ListBox::builder()
        .parent(&ui.window)
        .position((20, 430))
        .size((260, 180))
        .build(&mut ui.project_list)
        .map_err(gui_error)?;
    field(&ui.window, "项目编号", &mut ui.project_id, 300, 430)?;
    field(&ui.window, "项目名称", &mut ui.project_name, 300, 470)?;
    field(&ui.window, "项目根目录", &mut ui.project_path, 300, 510)?;
    button(&ui.window, "新建", &mut ui.new_project, 300, 560, 90)?;
    button(&ui.window, "保存", &mut ui.save_project, 400, 560, 90)?;
    button(&ui.window, "删除", &mut ui.delete_project, 500, 560, 90)?;

    label(&ui.window, "服务设置", (20, 630), (120, 24))?;
    small_field(&ui.window, "MCP 端口", &mut ui.port, 140, 625)?;
    button(
        &ui.window,
        "保存（重启后生效）",
        &mut ui.save_service,
        310,
        625,
        180,
    )?;
    label(
        &ui.window,
        "mDNS：_meno-agent._tcp.local  ·  防火墙：Private + LocalSubnet",
        (510, 630),
        (400, 24),
    )?;

    refresh_models(&ui, &store);
    refresh_projects(&ui, &store);
    if !store.snapshot().models.is_empty() {
        let config = store.snapshot();
        let index = config
            .current_model
            .as_deref()
            .and_then(|id| config.models.iter().position(|profile| profile.id == id))
            .unwrap_or(0);
        ui.model_list.set_selection(Some(index));
        load_selected_model(&ui, &store);
    }
    if !store.snapshot().workspaces.is_empty() {
        ui.project_list.set_selection(Some(0));
        load_selected_project(&ui, &store);
    }
    ui.port.set_text(&store.snapshot().port.to_string());

    let ui = Rc::new(ui);
    let event_ui = ui.clone();
    let event_store = store.clone();
    let handler = nwg::full_bind_event_handler(&ui.window.handle, move |event, _, handle| {
        use nwg::Event;
        if event == Event::OnWindowClose && handle == event_ui.window {
            nwg::stop_thread_dispatch();
        } else if event == Event::OnListBoxSelect && handle == event_ui.model_list {
            load_selected_model(&event_ui, &event_store);
        } else if event == Event::OnButtonClick && handle == event_ui.new_model {
            clear_model_form(&event_ui);
        } else if event == Event::OnButtonClick && handle == event_ui.save_model {
            show_result(save_model(&event_ui, &event_store));
            refresh_models(&event_ui, &event_store);
        } else if event == Event::OnButtonClick && handle == event_ui.delete_model {
            show_result(delete_model(&event_ui, &event_store));
            refresh_models(&event_ui, &event_store);
        } else if event == Event::OnButtonClick && handle == event_ui.select_model {
            show_result(select_model(&event_ui, &event_store));
            refresh_models(&event_ui, &event_store);
        } else if event == Event::OnButtonClick && handle == event_ui.test_model {
            test_model(&event_ui, &event_store);
        } else if event == Event::OnListBoxSelect && handle == event_ui.project_list {
            load_selected_project(&event_ui, &event_store);
        } else if event == Event::OnButtonClick && handle == event_ui.new_project {
            clear_project_form(&event_ui);
        } else if event == Event::OnButtonClick && handle == event_ui.save_project {
            show_result(save_project(&event_ui, &event_store));
            refresh_projects(&event_ui, &event_store);
        } else if event == Event::OnButtonClick && handle == event_ui.delete_project {
            show_result(delete_project(&event_ui, &event_store));
            refresh_projects(&event_ui, &event_store);
        } else if event == Event::OnButtonClick && handle == event_ui.save_service {
            show_result(save_service(&event_ui, &event_store));
        }
    });
    nwg::dispatch_thread_events();
    nwg::unbind_event_handler(&handler);
    Ok(())
}

fn save_model(ui: &SettingsUi, store: &ConfigStore) -> AgentResult<String> {
    let profile = profile_from_form(ui)?;
    let secret = ui.secret.text();
    if !secret.trim().is_empty() {
        credentials::write(&profile.credential, secret.trim())?;
    }
    let id = profile.id.clone();
    store.update(move |config| {
        if let Some(existing) = config.models.iter_mut().find(|item| item.id == id) {
            *existing = profile;
        } else {
            config.models.push(profile);
        }
        Ok(())
    })?;
    ui.secret.set_text("");
    Ok("模型配置已保存并立即生效".to_owned())
}

fn delete_model(ui: &SettingsUi, store: &ConfigStore) -> AgentResult<String> {
    let id = ui.model_id.text();
    validate_id(&id)?;
    store.update(|config| {
        config.models.retain(|profile| profile.id != id);
        if config.current_model.as_deref() == Some(id.as_str()) {
            config.current_model = config.models.first().map(|profile| profile.id.clone());
        }
        Ok(())
    })?;
    clear_model_form(ui);
    Ok("模型配置已删除".to_owned())
}

fn select_model(ui: &SettingsUi, store: &ConfigStore) -> AgentResult<String> {
    let id = ui.model_id.text();
    store.update(|config| {
        if !config.models.iter().any(|profile| profile.id == id) {
            return Err(AgentError::NotFound("请先保存该模型配置".to_owned()));
        }
        config.current_model = Some(id.clone());
        Ok(())
    })?;
    Ok("当前调查模型已切换".to_owned())
}

fn test_model(ui: &SettingsUi, store: &ConfigStore) {
    let result = save_model(ui, store).and_then(|_| {
        let id = ui.model_id.text();
        store
            .snapshot()
            .models
            .into_iter()
            .find(|profile| profile.id == id)
            .ok_or_else(|| AgentError::NotFound("模型配置不存在".to_owned()))
    });
    match result {
        Err(error) => show_result(Err(error)),
        Ok(profile) => {
            thread::spawn(move || {
                let result = (|| -> AgentResult<String> {
                    let runtime = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .map_err(|error| AgentError::Internal(error.to_string()))?;
                    runtime.block_on(ModelClient::new()?.test_profile(&profile))
                })();
                match result {
                    Ok(model) => nwg::simple_message(
                        "Windows Agent 设置",
                        &format!("连接成功，API 实际返回模型：{model}"),
                    ),
                    Err(error) => {
                        nwg::simple_message("Windows Agent 设置", &format!("连接失败：{error}"))
                    }
                }
            });
        }
    }
}

fn save_project(ui: &SettingsUi, store: &ConfigStore) -> AgentResult<String> {
    let id = ui.project_id.text();
    validate_id(&id)?;
    let name = ui.project_name.text().trim().to_owned();
    if name.is_empty() {
        return Err(AgentError::InvalidArgument("项目名称不能为空".to_owned()));
    }
    let path = std::fs::canonicalize(PathBuf::from(ui.project_path.text().trim()))?;
    if !path.is_dir() {
        return Err(AgentError::InvalidArgument("项目根目录不存在".to_owned()));
    }
    let item = WorkspaceConfig {
        id: id.clone(),
        name,
        path,
    };
    store.update(move |config| {
        if let Some(existing) = config.workspaces.iter_mut().find(|value| value.id == id) {
            *existing = item;
        } else {
            config.workspaces.push(item);
        }
        Ok(())
    })?;
    Ok("登记项目已保存并立即生效".to_owned())
}

fn delete_project(ui: &SettingsUi, store: &ConfigStore) -> AgentResult<String> {
    let id = ui.project_id.text();
    validate_id(&id)?;
    store.update(|config| {
        let before = config.workspaces.len();
        config.workspaces.retain(|workspace| workspace.id != id);
        if before == config.workspaces.len() {
            return Err(AgentError::NotFound("登记项目不存在".to_owned()));
        }
        Ok(())
    })?;
    clear_project_form(ui);
    Ok("登记项目已移除；磁盘内容未被删除".to_owned())
}

fn save_service(ui: &SettingsUi, store: &ConfigStore) -> AgentResult<String> {
    let port = ui
        .port
        .text()
        .parse::<u16>()
        .map_err(|_| AgentError::InvalidArgument("MCP 端口无效".to_owned()))?;
    store.update(|config| {
        config.port = port;
        Ok(())
    })?;
    Ok(if crate::request_firewall_update().is_ok() {
        "端口已保存，并已请求更新专用网络防火墙；请从 Meno 托盘退出并重新启动后生效".to_owned()
    } else {
        "端口已保存，但防火墙更新提权被取消或失败；重新启动前请再次保存服务设置".to_owned()
    })
}

fn profile_from_form(ui: &SettingsUi) -> AgentResult<ModelProfile> {
    let parse_price = |text: String| -> AgentResult<Option<f64>> {
        if text.trim().is_empty() {
            Ok(None)
        } else {
            text.trim()
                .parse::<f64>()
                .map(Some)
                .map_err(|_| AgentError::InvalidArgument("费用单价格式无效".to_owned()))
        }
    };
    let profile = ModelProfile {
        id: ui.model_id.text().trim().to_owned(),
        name: ui.model_name.text().trim().to_owned(),
        base_url: ui.base_url.text().trim().to_owned(),
        model: ui.model_name_api.text().trim().to_owned(),
        credential: ui.credential.text().trim().to_owned(),
        supports_images: ui.supports_images.check_state() == nwg::CheckBoxState::Checked,
        timeout_seconds: ui
            .timeout
            .text()
            .parse::<u64>()
            .map_err(|_| AgentError::InvalidArgument("模型超时格式无效".to_owned()))?,
        input_cost_per_million: parse_price(ui.input_cost.text())?,
        output_cost_per_million: parse_price(ui.output_cost.text())?,
    };
    profile.validate()?;
    Ok(profile)
}

fn refresh_models(ui: &SettingsUi, store: &ConfigStore) {
    let config = store.snapshot();
    ui.model_list.set_collection(
        config
            .models
            .iter()
            .map(|profile| {
                if config.current_model.as_deref() == Some(&profile.id) {
                    format!("● {} ({})", profile.name, profile.id)
                } else {
                    format!("  {} ({})", profile.name, profile.id)
                }
            })
            .collect(),
    );
}

fn refresh_projects(ui: &SettingsUi, store: &ConfigStore) {
    ui.project_list.set_collection(
        store
            .snapshot()
            .workspaces
            .iter()
            .map(|workspace| format!("{} ({})", workspace.name, workspace.id))
            .collect(),
    );
}

fn load_selected_model(ui: &SettingsUi, store: &ConfigStore) {
    let Some(index) = ui.model_list.selection() else {
        return;
    };
    let config = store.snapshot();
    let Some(profile) = config.models.get(index) else {
        return;
    };
    ui.model_id.set_text(&profile.id);
    ui.model_name.set_text(&profile.name);
    ui.base_url.set_text(&profile.base_url);
    ui.model_name_api.set_text(&profile.model);
    ui.credential.set_text(&profile.credential);
    ui.secret.set_text("");
    ui.supports_images
        .set_check_state(if profile.supports_images {
            nwg::CheckBoxState::Checked
        } else {
            nwg::CheckBoxState::Unchecked
        });
    ui.timeout.set_text(&profile.timeout_seconds.to_string());
    ui.input_cost.set_text(
        &profile
            .input_cost_per_million
            .map(|value| value.to_string())
            .unwrap_or_default(),
    );
    ui.output_cost.set_text(
        &profile
            .output_cost_per_million
            .map(|value| value.to_string())
            .unwrap_or_default(),
    );
}

fn load_selected_project(ui: &SettingsUi, store: &ConfigStore) {
    let Some(index) = ui.project_list.selection() else {
        return;
    };
    let config = store.snapshot();
    let Some(project) = config.workspaces.get(index) else {
        return;
    };
    ui.project_id.set_text(&project.id);
    ui.project_name.set_text(&project.name);
    ui.project_path
        .set_text(&crate::config::display_path(&project.path));
}

fn clear_model_form(ui: &SettingsUi) {
    ui.model_id.set_text("");
    ui.model_name.set_text("");
    ui.base_url.set_text("https://api.example.com/v1");
    ui.model_name_api.set_text("");
    ui.credential
        .set_text(&format!("WindowsAgent/Model/{}", uuid::Uuid::new_v4()));
    ui.secret.set_text("");
    ui.supports_images
        .set_check_state(nwg::CheckBoxState::Unchecked);
    ui.timeout.set_text("120");
    ui.input_cost.set_text("");
    ui.output_cost.set_text("");
}

fn clear_project_form(ui: &SettingsUi) {
    ui.project_id.set_text("");
    ui.project_name.set_text("");
    ui.project_path.set_text("");
}

fn show_result(result: AgentResult<String>) {
    match result {
        Ok(message) => nwg::simple_message("Windows Agent 设置", &message),
        Err(error) => nwg::simple_message("Windows Agent 设置", &format!("操作失败：{error}")),
    };
}

fn label(
    parent: &nwg::Window,
    text: &str,
    position: (i32, i32),
    size: (i32, i32),
) -> AgentResult<()> {
    let mut control = nwg::Label::default();
    nwg::Label::builder()
        .text(text)
        .parent(parent)
        .position(position)
        .size(size)
        .build(&mut control)
        .map_err(gui_error)?;
    // The parent window owns the native HWND lifetime. Keep the lightweight Rust
    // wrapper alive for the duration of this short-lived settings thread.
    std::mem::forget(control);
    Ok(())
}

fn field(
    parent: &nwg::Window,
    caption: &str,
    control: &mut nwg::TextInput,
    x: i32,
    y: i32,
) -> AgentResult<()> {
    label(parent, caption, (x, y), (175, 24))?;
    nwg::TextInput::builder()
        .parent(parent)
        .position((x + 180, y))
        .size((420, 25))
        .build(control)
        .map_err(gui_error)
}

fn small_field(
    parent: &nwg::Window,
    caption: &str,
    control: &mut nwg::TextInput,
    x: i32,
    y: i32,
) -> AgentResult<()> {
    label(parent, caption, (x, y), (110, 24))?;
    nwg::TextInput::builder()
        .parent(parent)
        .position((x + 112, y))
        .size((90, 25))
        .build(control)
        .map_err(gui_error)
}

fn button(
    parent: &nwg::Window,
    text: &str,
    control: &mut nwg::Button,
    x: i32,
    y: i32,
    width: i32,
) -> AgentResult<()> {
    nwg::Button::builder()
        .text(text)
        .parent(parent)
        .position((x, y))
        .size((width, 30))
        .build(control)
        .map_err(gui_error)
}

fn gui_error(error: nwg::NwgError) -> AgentError {
    AgentError::Internal(format!("设置窗口错误: {error}"))
}
