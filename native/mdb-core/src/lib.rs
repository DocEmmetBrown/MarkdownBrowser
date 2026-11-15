//! Native core of MarkdownBrowser, exposed to Swift through UniFFI.

uniffi::setup_scaffolding!();

pub mod markdown;
pub mod render;
pub mod search;
