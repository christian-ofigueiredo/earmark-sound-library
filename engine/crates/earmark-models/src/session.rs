//! Opening a model and running it on plain float arrays.

use ort::session::Session;
use ort::session::builder::{AutoDevicePolicy, GraphOptimizationLevel};
use ort::value::TensorRef;
use std::path::Path;
use std::sync::OnceLock;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ModelError {
    /// The model's file isn't there.
    NotInstalled(String),
    Runtime(String),
    /// Audio that couldn't be read.
    Audio(String),
}

impl std::fmt::Display for ModelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ModelError::NotInstalled(path) => write!(f, "the model isn't installed ({path})"),
            ModelError::Runtime(why) => write!(f, "the model couldn't run: {why}"),
            ModelError::Audio(why) => write!(f, "{why}"),
        }
    }
}

impl std::error::Error for ModelError {}

impl<R> From<ort::Error<R>> for ModelError {
    fn from(e: ort::Error<R>) -> ModelError {
        ModelError::Runtime(e.to_string())
    }
}

/// Where a model runs. The graphics card through DirectML on Windows; elsewhere always the processor.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Compute {
    Cpu,
    Gpu,
}

/// Half the processor's threads at most: analysis leaves room for the owner's work.
fn threads() -> usize {
    std::thread::available_parallelism()
        .map(|n| (n.get() / 2).max(1))
        .unwrap_or(1)
}

/// The one ONNX Runtime environment of the process. Telemetry off: Earmark reports nothing.
fn environment() -> Result<&'static ort::environment::Environment, ModelError> {
    static ENVIRONMENT: OnceLock<Result<ort::environment::Environment, String>> = OnceLock::new();
    ENVIRONMENT
        .get_or_init(|| {
            ort::init()
                .with_name("earmark")
                .with_telemetry(false)
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|e| ModelError::Runtime(e.clone()))
}

pub(crate) fn open(path: &Path, compute: Compute) -> Result<Session, ModelError> {
    if !path.is_file() {
        return Err(ModelError::NotInstalled(path.display().to_string()));
    }
    let builder = Session::builder(environment()?)?
        .with_optimization_level(GraphOptimizationLevel::All)?
        .with_intra_threads(threads())?
        // ONNX Runtime otherwise picks a device itself (Core ML on a Mac), and results
        // would differ from one computer to the next.
        .with_auto_device(AutoDevicePolicy::PreferCPU)?;
    let mut builder = accelerated(builder, compute)?;
    Ok(builder.commit_from_file(path)?)
}

#[cfg(windows)]
fn accelerated(
    builder: ort::session::builder::SessionBuilder,
    compute: Compute,
) -> Result<ort::session::builder::SessionBuilder, ModelError> {
    if compute == Compute::Cpu {
        return Ok(builder);
    }
    // DirectML takes one operation at a time and its own memory plan.
    Ok(builder
        .with_parallel_execution(false)?
        .with_memory_pattern(false)?
        .with_execution_providers([ort::ep::DirectML::default().build().error_on_failure()])?)
}

#[cfg(not(windows))]
fn accelerated(
    builder: ort::session::builder::SessionBuilder,
    _compute: Compute,
) -> Result<ort::session::builder::SessionBuilder, ModelError> {
    Ok(builder)
}

/// One output of a model: its shape and its values.
pub(crate) type Output = (Vec<i64>, Vec<f32>);

/// Runs a model with one float input; its float outputs by name, in the order asked.
pub(crate) fn run(
    session: &mut Session,
    input: &str,
    shape: &[i64],
    data: &[f32],
    outputs: &[&str],
) -> Result<Vec<Output>, ModelError> {
    let tensor = TensorRef::from_array_view((shape.to_vec(), data))?;
    let result = session.run(ort::inputs![input => tensor])?;
    outputs
        .iter()
        .map(|name| {
            let value = result
                .get(name)
                .ok_or_else(|| ModelError::Runtime(format!("no output “{name}”")))?;
            let (shape, values) = value.try_extract_tensor::<f32>()?;
            Ok((shape.to_vec(), values.to_vec()))
        })
        .collect()
}
