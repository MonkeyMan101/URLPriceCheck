#!/bin/bash
# Delegates to the copy under Application Support (local disk).
# launchd fails with I/O error if the job points at iCloud Drive paths.
exec "/Users/deanwass/Library/Application Support/URLPriceCheck/run-pricecheck.sh"
