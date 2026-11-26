use super::*;

struct Fixture(tempfile::TempDir);

impl Fixture {
    fn new() -> Self {
        Self(tempfile::tempdir().unwrap())
    }
    fn path(&self, relative: &str) -> PathBuf {
        if relative.is_empty() {
            self.0.path().to_owned()
        } else {
            self.0.path().join(relative)
        }
    }
    fn write(&self, relative: &str, data: &[u8]) {
        let path = self.path(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, data).unwrap();
    }
    fn scan(&self, provider: Provider) -> SourceReport {
        scan(&Source {
            provider,
            path: self.path(""),
        })
    }
}

#[test]
fn identifies_files_and_packages_without_listing_package_contents() {
    let fixture = Fixture::new();
    fixture.write("nested/模型.GGUF", b"one");
    fixture.write("nested/ignore.txt", b"no");
    fixture.write("visual.mlpackage/weights.bin", b"four");
    let report = fixture.scan(Provider::Custom);
    assert!(report.warnings.is_empty());
    let mut models = report.models;
    models.sort_by(|a, b| a.name.cmp(&b.name));
    assert_eq!(models.len(), 2);
    assert_eq!(
        (models[0].name.as_str(), models[0].bytes),
        ("nested/模型.GGUF", 3)
    );
    assert_eq!(
        (models[1].name.as_str(), models[1].bytes),
        ("visual.mlpackage", 4)
    );
}

#[test]
fn rescans_disk_after_add_remove_and_replace() {
    let fixture = Fixture::new();
    fixture.write("old.gguf", b"old");
    fixture.write("replace.gguf", b"old");
    assert_eq!(fixture.scan(Provider::Custom).models.len(), 2);

    fs::remove_file(fixture.path("old.gguf")).unwrap();
    fixture.write("new.gguf", b"new");
    fixture.write("replace.gguf", b"longer");
    let mut models = fixture.scan(Provider::Custom).models;
    models.sort_by(|a, b| a.name.cmp(&b.name));
    assert_eq!(models.len(), 2);
    assert_eq!(models[0].name, "new.gguf");
    assert_eq!(
        (models[1].name.as_str(), models[1].bytes),
        ("replace.gguf", 6)
    );
}

#[test]
fn labels_comfy_models_inside_install_and_external_category() {
    let fixture = Fixture::new();
    fixture.write("models/checkpoints/nested/example.safetensors", b"x");
    let install = chosen_source(Provider::ComfyUi, fixture.path("")).unwrap();
    assert_eq!(scan(&install).models[0].category, "checkpoints");
    let external = chosen_source(Provider::ComfyUi, fixture.path("models/checkpoints")).unwrap();
    assert_eq!(scan(&external).models[0].category, "checkpoints");
}

#[test]
fn reports_missing_source_instead_of_silently_returning_empty() {
    let fixture = Fixture::new();
    let report = scan(&Source {
        provider: Provider::Custom,
        path: fixture.path("missing"),
    });
    assert!(report.models.is_empty());
    assert_eq!(report.warnings.len(), 1);
}

#[test]
fn reads_valid_ollama_manifests_and_reports_corruption() {
    let fixture = Fixture::new();
    fixture.write(
        "manifests/registry.ollama.ai/library/example/latest",
        br#"{"config":{"size":2},"layers":[{"size":9}]}"#,
    );
    fixture.write(
        "manifests/registry.ollama.ai/library/example/bad",
        b"broken",
    );
    fixture.write("blobs/not-a-manifest", b"ignored");
    let report = fixture.scan(Provider::Ollama);
    assert_eq!(report.warnings.len(), 1);
    assert_eq!(report.models.len(), 1);
    assert_eq!(
        (report.models[0].name.as_str(), report.models[0].bytes),
        ("library/example:latest", 11)
    );
}

#[test]
fn groups_hf_by_repo_not_by_weight_file() {
    let fixture = Fixture::new();
    fixture.write("models--org--repo/blobs/a", b"blob");
    fixture.write("models--org--repo/refs/main", b"ref");
    fixture.write("outside/ignore.gguf", b"ignored");
    let report = fixture.scan(Provider::HuggingFace);
    assert!(report.warnings.is_empty());
    assert_eq!(report.models.len(), 1);
    assert_eq!(
        (report.models[0].name.as_str(), report.models[0].bytes),
        ("org/repo", 7)
    );
}

#[cfg(unix)]
#[test]
fn skips_directory_and_snapshot_links() {
    use std::os::unix::fs::symlink;
    let fixture = Fixture::new();
    let external = Fixture::new();
    external.write("hidden.gguf", b"outside");
    fixture.write("models--org--repo/blobs/a", b"blob");
    fs::create_dir_all(fixture.path("models--org--repo/snapshots")).unwrap();
    symlink(
        fixture.path("models--org--repo/blobs/a"),
        fixture.path("models--org--repo/snapshots/copy"),
    )
    .unwrap();
    symlink(external.path(""), fixture.path("linked")).unwrap();
    assert_eq!(fixture.scan(Provider::HuggingFace).models[0].bytes, 4);
    assert!(fixture.scan(Provider::Custom).models.is_empty());
}

#[cfg(windows)]
#[test]
fn skips_windows_junctions() {
    let fixture = Fixture::new();
    let external = Fixture::new();
    external.write("hidden.gguf", b"outside");
    let junction = fixture.path("linked");
    let status = std::process::Command::new("cmd")
        .args(["/C", "mklink", "/J"])
        .arg(&junction)
        .arg(external.path(""))
        .status()
        .unwrap();
    assert!(status.success());
    assert!(fixture.scan(Provider::Custom).models.is_empty());
}
