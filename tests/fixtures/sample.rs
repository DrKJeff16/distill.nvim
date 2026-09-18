use log::info;

fn run(x: i32) -> i32 {
    info!("start {}", x); // @log
    log::warn!("multi", // @log
        x);
    tracing::debug!(a = 1, "b"); // @log
    println!("print"); // @print
    dbg!(x); // @print
    let y = compute(x);
    assert!(y > 0);
    y
}
