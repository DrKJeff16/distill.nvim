import { logger } from "./logger";

function run(items) {
  console.error("bad"); // @log
  logger.info("start", { items }); // @log
  logger.debug( // @log
    "multi",
    items,
  );
  console.log("print"); // @print
  const r = Math.log(10);
  const s = compute(r);
  return items.map((i) => i * r + s);
}
