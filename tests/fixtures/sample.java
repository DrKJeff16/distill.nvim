class Sample {
  void run(int x) {
    logger.info("start"); // @log
    log.debug("multi", // @log
        x);
    this.logger.warn("a"); // @log
    Log.d(TAG, "android"); // @log
    System.out.println("print"); // @print
    e.printStackTrace(); // @print
    int y = Math.max(x, 1);
    compute(y);
  }
}
