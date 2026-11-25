//! On Windows, puts Earmark's icon and name in the .exe.

fn main() {
    #[cfg(windows)]
    {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("assets/icon.ico");
        res.set("ProductName", "Earmark");
        res.set("FileDescription", "Earmark");
        if let Err(e) = res.compile() {
            println!("cargo:warning=Couldn't add the icon to the .exe: {e}");
        }
    }
    println!("cargo:rerun-if-changed=assets/icon.ico");
}
