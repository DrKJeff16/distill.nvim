func run(_ x: Int) {
    logger.info("start") // @log
    Logger.shared.debug("multi", // @log
        x)
    NSLog("nslog") // @log
    print("print") // @print
    let y = compute(x)
}
