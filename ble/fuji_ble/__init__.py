"""fuji_ble: Bluetooth LE client for the Fujifilm X100VI (dialin).

Modules:
  gatt     X100VI GATT map with source citations, advert/value decoders, file-service framing (pure, no I/O)
  client   bleak transport, session, and the scan / pair / dump / backup / watch / restore flows
  cli      `python -m fuji_ble ...`
  fake     simulated X100VI for rehearsal (--fake) and tests

Importing the package does not import bleak; only real Bluetooth commands do.
"""

__version__ = "0.1.0"
