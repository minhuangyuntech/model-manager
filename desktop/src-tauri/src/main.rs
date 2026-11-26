#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod scanner;

use scanner::{Provider, Source, SourceReport};
use tauri_plugin_dialog::DialogExt;

#[tauri::command]
fn default_sources() -> Vec<Source> {
    scanner::default_sources()
}

#[tauri::command]
async fn choose_source(
    app: tauri::AppHandle,
    provider: Provider,
) -> Result<Option<Source>, String> {
    let Some(folder) = app.dialog().file().blocking_pick_folder() else {
        return Ok(None);
    };
    let path = folder.into_path().map_err(|error| error.to_string())?;
    scanner::chosen_source(provider, path)
        .map(Some)
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn scan_sources(sources: Vec<Source>) -> Result<Vec<SourceReport>, String> {
    tauri::async_runtime::spawn_blocking(move || sources.iter().map(scanner::scan).collect())
        .await
        .map_err(|error| error.to_string())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            default_sources,
            choose_source,
            scan_sources
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Local Model Manager");
}
