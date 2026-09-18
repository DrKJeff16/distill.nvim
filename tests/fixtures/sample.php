<?php
function run($x) {
    $this->logger->info("start"); // @log
    Log::debug("multi", // @log
        ['x' => $x]);
    error_log("err"); // @log
    Logger::getLogger()->warning("w"); // @log
    var_dump($x); // @print
    $y = strlen($x);
    $z = $stmt->errorInfo();
}
