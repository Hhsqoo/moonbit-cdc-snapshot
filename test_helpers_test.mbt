///|
/// Remove one test-owned tree recursively. Test paths use unique fixed names
/// below the module workspace and never point outside the checkout.
fn remove_tree(path : String) -> Unit {
  if !@fs.path_exists(path) {
    return
  }
  let is_dir = @fs.is_dir(path) catch { _ => false }
  if is_dir {
    let names : ArrayView[String] = @fs.read_dir(path) catch { _ => [] }
    for name in names {
      remove_tree(path + "/" + name)
    }
    @fs.remove_dir(path) catch {
      _ => ()
    }
  } else {
    @fs.remove_file(path) catch {
      _ => ()
    }
  }
}
