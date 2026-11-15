fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args_os()
        .nth(1)
        .ok_or("Usage: syntax_notices <two-face LICENSE-MIT path>")?;
    let license = std::fs::read_to_string(path)?;
    println!(
        "two-face syntax definitions\n\nUpstream acknowledgements: {}\n\n{}\n\n{}",
        two_face::acknowledgement::url(),
        license,
        two_face::acknowledgement::listing().to_md()
    );
    Ok(())
}
