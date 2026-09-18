#include <iostream>

void run(int x) {
  spdlog::info("start {}", x); // @log
  logger->debug("y"); // @log
  LOG(INFO) << "stream " // @log
            << x;
  qDebug() << "qt"; // @log
  std::cout << "print" << x << std::endl; // @print
  printf("print"); // @print
  int y = x << 2;
  int z = compute(y);
  err.error();
}
