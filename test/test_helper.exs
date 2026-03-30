# Ensure tmp directory exists for test CSV files
File.mkdir_p!("tmp")

# capture_log: true suppresses log output during tests (including Req.Test.Ownership
# errors that occur when tasks are killed mid-request)
ExUnit.start(capture_log: true)
