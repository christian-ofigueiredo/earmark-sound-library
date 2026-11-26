//! Playing a sound or a song: one at a time, from the file where it is (read only).

use std::path::Path;

pub struct Player {
    stream: Option<rodio::MixerDeviceSink>,
    sink: Option<rodio::Player>,
    /// What's playing.
    pub path: Option<String>,
}

impl Player {
    pub fn new() -> Self {
        Player {
            stream: None,
            sink: None,
            path: None,
        }
    }

    /// Plays the file, or stops it when it's the one playing.
    pub fn toggle(&mut self, path: &str) -> Result<(), String> {
        if self.path.as_deref() == Some(path) && self.is_playing() {
            self.stop();
            return Ok(());
        }
        self.play(path)
    }

    pub fn play(&mut self, path: &str) -> Result<(), String> {
        self.stop();
        if self.stream.is_none() {
            let mut stream = rodio::DeviceSinkBuilder::open_default_sink()
                .map_err(|e| format!("No sound output: {e}"))?;
            stream.log_on_drop(false);
            self.stream = Some(stream);
        }
        let file = std::fs::File::open(Path::new(path)).map_err(|e| e.to_string())?;
        let source = rodio::Decoder::try_from(file).map_err(|e| e.to_string())?;
        let stream = self.stream.as_ref().expect("opened above");
        let sink = rodio::Player::connect_new(stream.mixer());
        sink.append(source);
        self.sink = Some(sink);
        self.path = Some(path.to_string());
        Ok(())
    }

    pub fn stop(&mut self) {
        if let Some(sink) = self.sink.take() {
            sink.stop();
        }
        self.path = None;
    }

    pub fn is_playing(&self) -> bool {
        self.sink.as_ref().is_some_and(|s| !s.empty())
    }

    /// Forgets a sound that ended by itself. Answers whether one did.
    pub fn tick(&mut self) -> bool {
        if self.path.is_some() && !self.is_playing() {
            self.sink = None;
            self.path = None;
            return true;
        }
        false
    }
}
