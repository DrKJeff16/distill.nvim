void run(int x) {
  logger.i('start'); // @log
  Logger.root.info('multi', // @log
      x);
  developer.log('dev'); // @log
  print('print'); // @print
  debugPrint('print'); // @print
  var y = compute(x);
  compute(x);
}
