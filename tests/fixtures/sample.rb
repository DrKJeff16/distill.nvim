def run(x)
  logger.info "start" # @log
  Rails.logger.debug("y") # @log
  logger.warn do # @log
    "block"
  end
  warn "stderr" # @log
  puts "print" # @print
  p x # @print
  y = x.map { |i| i + 1 }
  compute(y)
end
