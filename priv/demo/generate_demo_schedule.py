#!/usr/bin/env python3
"""Regenerate the synthetic annual fixture; deployment imports the checked-in CSV.

Run --help for reproducible CP-SAT options. No real resident schedule is read.
"""

from optimize_demo_schedule import main


if __name__ == "__main__":
    main()
