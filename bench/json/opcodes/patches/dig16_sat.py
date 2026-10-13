"""Digits: dig16 with the digit test as a saturating subtract (uqsub / psubusb) instead of an unsigned compare."""
from _dig import make, SAT
patch = make(SAT)
