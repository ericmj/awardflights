# Award Flights

A Phoenix LiveView app for scanning SAS EuroBonus award flight availability and finding round trip combinations.

## Features

- **Flight Scanner** -- Scans SAS award flight availability across multiple routes and date ranges with configurable parallelism
  - Supports both the Partner API (award-api) and SAS Direct API (offers-api)
  - Multiple credential rotation with automatic rate limit handling
  - Skip already-scanned routes within a configurable time window
  - Real-time progress updates via LiveView
- **Trip Correlator** -- Finds round trip combinations from scanned results
  - Filter by airports, date ranges, trip duration, cabin class, and source (SAS/Partner)
  - Displays airline names, booking classes, and seat availability
  - Exports results to CSV

## Setup

```bash
mix setup
mix phx.server
```

Visit [localhost:4000](http://localhost:4000) for the scanner and [localhost:4000/trips](http://localhost:4000/trips) for the trip correlator.

## Authentication

The scanner requires SAS EuroBonus session credentials. Add them through the web UI:

- **Partner API** -- Cookie or bearer token from an authenticated sas.se session
- **SAS Direct API** -- Auth token and cookies from an authenticated sas.se session

## Output

Scan results are saved to `results.csv` and trip correlator results to `trips.csv`.
