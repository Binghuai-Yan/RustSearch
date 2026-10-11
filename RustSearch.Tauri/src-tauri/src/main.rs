#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod backend;
mod desktop;
use backend::Backend;
use desktop::Desktop;
use serde_json::Value;
use tauri::{Manager, State};
use tauri_plugin_opener::OpenerExt;

#[tauri::command]
async fn backend_call(
    app: tauri::AppHandle,
    backend: State<'_, Backend>,
    method: String,
    params: Value,
) -> Result<Value, String> {
    let desktop = app.state::<Desktop>();
    let _gate = desktop
        .gate
        .try_read()
        .map_err(|_| "正在迁移数据，请稍候。")?;
    backend.call(&app, &method, params).await
}

#[tauri::command]
fn open_local_path(app: tauri::AppHandle, path: String, reveal: bool) -> Result<(), String> {
    let file = std::path::Path::new(&path);
    if !file.is_absolute() || !file.exists() {
        return Err("文件已移动、删除或路径无效。".into());
    }
    if reveal {
        app.opener()
            .reveal_item_in_dir(file)
            .map_err(|e| e.to_string())
    } else {
        app.opener()
            .open_path(file.to_string_lossy(), None::<&str>)
            .map_err(|e| e.to_string())
    }
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _| {
            if args.iter().any(|a| a == "--exit") {
                app.exit(0);
            } else {
                show_window(app);
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(Backend::default())
        .manage(Desktop::default())
        .setup(|app| {
            if std::env::args().any(|a| a == "--exit") {
                app.handle().exit(0);
                return Ok(());
            }
            use tauri::{
                menu::{Menu, MenuItem},
                tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
            };
            let show = MenuItem::with_id(app, "show", "打开 RustSearch Tauri", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("RustSearch Tauri")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if matches!(
                        event,
                        TrayIconEvent::Click {
                            button: MouseButton::Left,
                            button_state: MouseButtonState::Up,
                            ..
                        }
                    ) {
                        show_window(tray.app_handle());
                    }
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let desktop = window.state::<Desktop>();
                if desktop.close_to_tray()
                    || desktop.migrating.load(std::sync::atomic::Ordering::SeqCst)
                {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            backend_call,
            open_local_path,
            desktop::desktop_settings,
            desktop::save_desktop_settings,
            desktop::change_data_directory,
            desktop::cancel_migration
        ])
        .build(tauri::generate_context!())
        .expect("无法启动 RustSearch");
    app.run(|handle, event| {
        if let tauri::RunEvent::ExitRequested { ref api, .. } = event {
            let desktop = handle.state::<Desktop>();
            if desktop.migrating.load(std::sync::atomic::Ordering::SeqCst) {
                api.prevent_exit();
                desktop.request_cancel();
                let app = handle.clone();
                tauri::async_runtime::spawn(async move {
                    let desktop = app.state::<Desktop>();
                    let _gate = desktop.gate.write().await;
                    app.exit(0);
                });
            }
        }
        if matches!(event, tauri::RunEvent::Exit) {
            tauri::async_runtime::block_on(handle.state::<Backend>().disconnect());
        }
    });
}

fn show_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}
