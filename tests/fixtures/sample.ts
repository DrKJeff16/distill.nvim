import { logger } from "./logger";

export function run(items: number[]): number {
  console.warn("bad"); // @log
  logger.info<string>("start"); // @log
  this.log.debug( // @log
    "multi",
    items,
  );
  console.log("print"); // @print
  const r: number = Math.log(10);
  return items.length + r;
}
