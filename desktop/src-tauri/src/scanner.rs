use serde::{Deserialize, Serialize};
use std::{
    env, fs, io,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Provider {
    Ollama,
    LmStudio,
    HuggingFace,
    ComfyUi,
    Custom,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Source {
    pub provider: Provider,
    pub path: PathBuf,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    pub name: String,
    pub relative_path: String,
    pub path: PathBuf,
    pub format: String,
    pub category: String,
    pub bytes: u64,
    pub modified: Option<u64>,
}

#[derive(Default, Serialize)]
pub struct SourceReport {
    pub models: Vec<Model>,
    pub warnings: Vec<String>,
    pub omitted_warnings: usize,
}

impl SourceReport {
    fn warn(&mut self, path: &Path, error: impl std::fmt::Display) {
        if self.warnings.len() < 50 {
            self.warnings.push(format!("{}：{error}", path.display()));
        } else {
            self.omitted_warnings += 1;
        }
    }
}

fn env_path(key: &str) -> Option<PathBuf> {
    env::var_os(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

pub fn default_sources() -> Vec<Source> {
    let mut sources = Vec::new();
    let mut add = |provider, path: Option<PathBuf>| {
        if let Some(path) = path.filter(|path| path.to_str().is_some()) {
            if !sources.iter().any(|source: &Source| source.path == path) {
                sources.push(Source { provider, path });
            }
        }
    };
    let home = dirs::home_dir();
    let under_home = |directory: &str| home.as_ref().map(|path| path.join(directory));
    add(
        Provider::Ollama,
        env_path("OLLAMA_MODELS").or_else(|| under_home(".ollama/models")),
    );
    add(Provider::LmStudio, under_home(".lmstudio/models"));
    add(
        Provider::HuggingFace,
        env_path("HF_HUB_CACHE").or_else(|| {
            env_path("HF_HOME")
                .or_else(|| under_home(".cache/huggingface"))
                .map(|path| path.join("hub"))
        }),
    );

    let candidates = [
        home.clone(),
        dirs::document_dir(),
        dirs::download_dir(),
        dirs::desktop_dir(),
        under_home("Applications"),
        under_home("comfy"),
    ];
    for directory in candidates.into_iter().flatten() {
        let models = directory.join("ComfyUI/models");
        add(Provider::ComfyUi, models.is_dir().then_some(models));
    }
    if let Some(installs) = under_home("ComfyUI-Installs").and_then(|path| fs::read_dir(path).ok())
    {
        for install in installs.flatten() {
            for relative in ["models", "ComfyUI/models"] {
                let models = install.path().join(relative);
                add(Provider::ComfyUi, models.is_dir().then_some(models));
            }
        }
    }
    if let Some(base) = dirs::config_dir()
        .and_then(|dir| fs::read(dir.join("ComfyUI/config.json")).ok())
        .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
        .and_then(|config| config.get("basePath")?.as_str().map(str::to_owned))
    {
        let base = match base.strip_prefix("~/") {
            Some(relative) => under_home(relative),
            None => Some(PathBuf::from(base)),
        };
        if let Some(models) = base
            .filter(|path| path.is_absolute())
            .map(|path| path.join("models"))
        {
            add(Provider::ComfyUi, models.is_dir().then_some(models));
        }
    }
    sources
}

pub fn chosen_source(provider: Provider, path: PathBuf) -> io::Result<Source> {
    if !path.is_absolute() || !fs::metadata(&path)?.is_dir() {
        return Err(io::Error::other("請選擇有效的資料夾。"));
    }
    let models = path.join("models");
    let path = if provider == Provider::ComfyUi && models.is_dir() {
        models
    } else {
        path
    };
    if path.to_str().is_none() {
        return Err(io::Error::other("資料夾路徑包含無法顯示的字元。"));
    }
    Ok(Source { provider, path })
}

pub fn scan(source: &Source) -> SourceReport {
    let mut report = SourceReport::default();
    let root = &source.path;
    let provider = source.provider;
    if !root.is_absolute() {
        report.warn(root, "來源必須是絕對路徑。");
        return report;
    }
    match fs::metadata(root) {
        Ok(metadata) if metadata.is_dir() => (),
        Ok(_) => {
            report.warn(root, "來源不是資料夾。");
            return report;
        }
        Err(error) => {
            report.warn(root, error);
            return report;
        }
    }

    if provider == Provider::HuggingFace {
        visit(root, &mut report, |path, metadata, report| {
            if let Some(name) = path
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| name.strip_prefix("models--"))
            {
                if metadata.is_dir() {
                    let (bytes, modified) = directory_stats(path, metadata, report);
                    push(
                        report,
                        root,
                        path,
                        name.replace("--", "/"),
                        "HF 快取",
                        "HF 快取",
                        (bytes, modified),
                    );
                }
            }
            false
        });
    } else if provider == Provider::Ollama {
        let manifests = root.join("manifests");
        match fs::symlink_metadata(&manifests) {
            Ok(metadata) if metadata.is_dir() && !is_link(&metadata) => {
                visit(&manifests, &mut report, |path, metadata, report| {
                    if metadata.is_file() {
                        let relative = relative_path(path, &manifests);
                        let parts: Vec<_> = relative.split('/').collect();
                        let name = if parts.len() >= 3 {
                            format!(
                                "{}:{}",
                                parts[1..parts.len() - 1].join("/"),
                                parts[parts.len() - 1]
                            )
                        } else {
                            relative
                        };
                        match manifest_size(path) {
                            Ok(bytes) => push(
                                report,
                                root,
                                path,
                                name,
                                "Ollama",
                                "Ollama",
                                (bytes, modified(metadata)),
                            ),
                            Err(error) => report.warn(path, error),
                        }
                    }
                    true
                });
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => report.warn(&manifests, error),
            Ok(_) => report.warn(&manifests, "已略過連結或非資料夾的 manifests。"),
        }
    } else {
        visit(root, &mut report, |path, metadata, report| {
            let extension = path
                .extension()
                .and_then(|value| value.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            let package = metadata.is_dir() && extension == "mlpackage";
            let format = extension.to_ascii_uppercase();
            if package
                || (metadata.is_file()
                    && [
                        "gguf",
                        "ggml",
                        "safetensors",
                        "ckpt",
                        "sft",
                        "bin",
                        "pt",
                        "pth",
                        "onnx",
                        "mlmodel",
                        "mlpackage",
                    ]
                    .contains(&extension.as_str()))
            {
                let stats = if package {
                    directory_stats(path, metadata, report)
                } else {
                    (metadata.len(), modified(metadata))
                };
                let name = relative_path(path, root);
                let category = if provider == Provider::ComfyUi {
                    comfy_category(root, &name).to_owned()
                } else {
                    format.clone()
                };
                push(report, root, path, name, &format, &category, stats);
            }
            !package
        });
    }
    report
}

// A selected source root may be a link. Links encountered inside it are not followed,
// including Windows junctions and other reparse points.
fn is_link(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    metadata.is_symlink()
}

fn visit(
    root: &Path,
    report: &mut SourceReport,
    mut entry: impl FnMut(&Path, &fs::Metadata, &mut SourceReport) -> bool,
) {
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let children = match fs::read_dir(&directory) {
            Ok(children) => children,
            Err(error) => {
                report.warn(&directory, error);
                continue;
            }
        };
        for child in children {
            let path = match child {
                Ok(child) => child.path(),
                Err(error) => {
                    report.warn(&directory, error);
                    continue;
                }
            };
            match fs::symlink_metadata(&path) {
                Ok(meta) if !is_link(&meta) => {
                    if entry(&path, &meta, report) && meta.is_dir() {
                        pending.push(path);
                    }
                }
                Ok(_) => (),
                Err(error) => report.warn(&path, error),
            }
        }
    }
}

fn relative_path(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .components()
        .map(|part| part.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

fn modified(metadata: &fs::Metadata) -> Option<u64> {
    metadata
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_millis()
        .try_into()
        .ok()
}

fn directory_stats(
    path: &Path,
    metadata: &fs::Metadata,
    report: &mut SourceReport,
) -> (u64, Option<u64>) {
    let mut bytes = 0u64;
    let mut latest = modified(metadata);
    visit(path, report, |_, meta, _| {
        if meta.is_file() {
            bytes = bytes.saturating_add(meta.len());
        }
        latest = latest.max(modified(meta));
        true
    });
    (bytes, latest)
}

fn push(
    report: &mut SourceReport,
    root: &Path,
    path: &Path,
    name: String,
    format: &str,
    category: &str,
    (bytes, modified): (u64, Option<u64>),
) {
    // Only JSON-representable paths can be shown by the UI. Keep other rows usable.
    if path.to_str().is_none() {
        report.warn(path, "路徑包含無法顯示的字元，已略過。");
        return;
    }
    report.models.push(Model {
        name,
        relative_path: relative_path(path, root),
        path: path.to_owned(),
        format: format.into(),
        category: category.into(),
        bytes,
        modified,
    });
}

fn comfy_category(root: &Path, relative: &str) -> &'static str {
    let categories = [
        "checkpoints",
        "loras",
        "vae",
        "controlnet",
        "upscale_models",
        "embeddings",
        "clip",
        "clip_vision",
        "text_encoders",
        "diffusion_models",
        "unet",
        "ipadapter",
        "style_models",
        "audio_encoders",
        "background_removal",
        "detection",
        "diffusers",
        "frame_interpolation",
        "geometry_estimation",
        "gligen",
        "hypernetworks",
        "latent_upscale_models",
        "model_patches",
        "optical_flow",
        "photomaker",
        "vae_approx",
    ];
    categories
        .into_iter()
        .find(|category| {
            root.file_name().is_some_and(|name| name == *category)
                || relative
                    .rsplit_once('/')
                    .is_some_and(|(parents, _)| parents.split('/').any(|part| part == *category))
        })
        .unwrap_or("其他模型")
}

fn manifest_size(path: &Path) -> Result<u64, Box<dyn std::error::Error>> {
    #[derive(Deserialize)]
    struct Layer {
        size: u64,
    }
    #[derive(Deserialize)]
    struct Manifest {
        config: Option<Layer>,
        layers: Vec<Layer>,
    }
    // A manifest should contain metadata, not weights. Bound input before parsing.
    use std::io::Read;
    const MAX_BYTES: u64 = 4 * 1024 * 1024;
    let mut data = Vec::new();
    fs::File::open(path)?
        .take(MAX_BYTES + 1)
        .read_to_end(&mut data)?;
    if data.len() as u64 > MAX_BYTES {
        return Err(io::Error::other("Ollama manifest 過大。").into());
    }
    let manifest: Manifest = serde_json::from_slice(&data)?;
    Ok(manifest.layers.into_iter().fold(
        manifest.config.map_or(0, |layer| layer.size),
        |size, layer| size.saturating_add(layer.size),
    ))
}

#[cfg(test)]
mod tests;
