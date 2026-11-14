"""Encoded narrowband, wideband and ultra-wideband versions of an authored sine."""

from base64 import b64decode
from zlib import decompress


# Speex 1.2.1, quality 3, with 1.25 seconds of 440 Hz mono PCM in each native band.
TONES = {
    "nb": (
        b"eNqlU21MW1UYpis0k62X8bHSbi1UcHKTsbISp7R1p845Kz/GWYXhOu0iri1qTKnpx9hCXDqEWzYgWVi8yUZ3ltQl"
        b"OhlKmmjXGT9yx0Roi5iMpGYkNgIVqcFE/WFimOeeW0uX+M+TNG2fvO95nud9zgs7O1sLNhVkz/KK5S3++9Rv6W7R"
        b"kVaX3d6tVqu1mkaNtuDhI8KfI/jzTLXwvzCLPcDnWl5N/oE8V0E+F19xf0KzW6SW41+HnCe7bHab+tQbntfVAnmO"
        b"mvQWbqvb6OVFK6uvS4wV/+/I2wbUBbqEa1vrH8qtF8+8CLuS0/K2wNLfD379fr3INkrNWWbhuwkKYyuml/YNVhW+"
        b"H0Wyswxk7Hcw9kuP8cntoDEVRQqfCfZHLPi+HT26hBco03ok9llZ/60EqTvOqUAR60DU1AIcLhIwoPOCqjSFSmd+"
        b"hwOO2VxvFe5V7AyygWxvz+k4kMjvIln/h7BXx+VxGBood5Ad0Al1Rl0fqNFRqNjdB/23NQSzJ/qA8ik9Kt0ZhgNN"
        b"p3O91ZV6RLkZliG9K8csSS+QvIK99VshI93geOy/OFYEDob3geukWS2luI7J1h2dw/dV7kBU78cwMJQk2IFEHNTz"
        b"3nwdmCOZx4Fn5Q5CZlLofSShAns/G0fSY5NwMOIUfCRVoBH7ECkXINFCen0nJGniA/7Lq0jITtSnHajMZ4X+LLal"
        b"MQ52XYwisWuB7b8gzGX/rBfUsgD3BuEFg4A9XYtnpR1GpZEw9C9TeXkYGhR53miLF6j5zKew5gPcQz5KZFaWaRI0"
        b"b+6Kjakzl5Fshueoyfrg81hG5e4wO2y/J8wKz74K51GCfQSGWgim/Q7PL4M14zwG7yVzfmuwFhHWPJzVsh/z1gAH"
        b"kkU2Mrfh+wrxuyrjM7c5cxk1kllhzVJ+fsrPyRtK3ea90ZmIwGvQeUKXlhxIfLeD/in1pjAXpyc0MVqFirkgvTb8"
        b"LcGs5++EWNGzaFNMRS/ZLQR7R2zHu7BunqXOwoA9SXbm1eLD4NH6qHn++Q54buIvzKswNTlV/KxS0+VYC3njq4w4"
        b"PTZWppw3T8sq6bWonNynUXhC7NYfUElM5crYFQIHN8SFe2+g8l7GtXirjmAvnKwIfbD6Gtrix3UfGYV3ulcZ+iSi"
        b"QdWfHnRlrncImEbFBW1XUcnLk/TaF+ezeYyF3susozJlNZ3Z00xm1Zz0hMLaKJK6g66fv54n+/FcYh93afRx8zft"
        b"b+M32UK8GZvioPay3sxtH4H+wzGC7WmWgrIIlZrWh/Gukt0y1dcdBarOdiSZYegf7+sIb1vSy93EPnDm9OLN3QQr"
        b"SnhCX5bcQIorQXrpq5Zs5rFQcMTB74drVd5NtOzSxbnRJ8bNU8dHYCBCMFP7mUlQeUifmjsHWWaxQeWcU5g6XBXj"
        b"11J685+bY8XGoOEfsiRPiw=="
    ),
    "wb": (
        b"eNqlVH1ME2ccvvJV5asgSUehhW6y7BxwgCRIWzk0S0dMBocDDRhLQqB0H667pR/g1rESpIVZmUnZumQ0r/G2mUV0"
        b"VjSbHQvChbgMehtL5laniWVCAUFijBkui+69a8sd7s+9yaWXPn1+z/N73t+vhMHQgMQh0bOw1HyE/Vz7ItAjqm8g"
        b"9foupVJZhu3EypDNRwSfevjY8ch7QvS7J/DsEfG/ER6C1UKEWuwvbvqwQpEyG75pjW1vt+vblZ2vm19TRsQ3pDlu"
        b"grKO57Km+345ZauW/b+T3TiQgagYMuNwArI1/9ULSdpnt7jH1XvE2Y39tzXB9eMuUxMOkpvXiJ6q824HgrDAUs37"
        b"NY3U+buDINlVTAxW/RQDlm0JJbW49KYfpJBewn4lyAMaTQAvWlWDeGsr4VTRUWAgx6ZiLPhzYTVIN3k9x1WM21Ga"
        b"ygLyMRbI/0wNMk1eyJiDQJShD1pbKiBDMj1KOAcYXuMlKL59lx/E5+kI+/e0AMBmRsTXbwCpVUc4G9v+K76N1Zhi"
        b"YhrysTRW3LMApLleop8VRzbELbg8Ypfov3PU7RC5IgwNZm0piACFW/pYV6kR8aa9FrxoKQlIGCj+3Xa+VKXRgsdF"
        b"SzkTY4wBWRPrSh511XMFAmV23pWc65yNBAIieydX6h3aPCIPa0pkpg3AwDG0HENTIvnhFtH/bR0LsK5WxlR1U/iL"
        b"6wtARt739KjT+ayKjOdwhQfGPt1HOCuNgqyCkVLsfbjYq42UWrY1z8KrXZmErq4RzvlHm9MtgIz0mKvKVAMHaKOx"
        b"S3N7iR4/xotj0st4fOsgyNb1EXbmax5gY9+5K5278w9PCOaq+REE7i4ACbkK7Tbz4vtinWc9FUm70TySBIHUmCsE"
        b"MXClqoIKPGElGWQHvMTgps5hqZxI5x6OUYp0cowDszMjRe91gDiTk3CmtgmmvRSKF8FJrNARrgn66UjgGmwaOE7c"
        b"gmd5FkK/X3yGcIXLYwxZTRptwfPC6tBs71nCobrH72D3j7V48WFH6KpvlnB1yHhG7UQALwj5Q0zG/UIx3+BSzY59"
        b"VfSQqQWI/3ajK2dQ3q6WGaF8vjyQac5H5w3rgmlnzNTFFT87ouTtE3RsRHNsBxgL7WAbNHnRkEqwas9bA/THXR1A"
        b"/G4D+edXb/BAChagfcNxQNZ1Cw31LwoYRxX06c+vg0TTKLp2Y6sAUF2iPnn4GC5OFrn4h0xgN2ihPx2eOyg9JkaX"
        b"/7nGRyKu1OHFyf799MSvxLGpn4Wxy6nh8g6uj/AZjF9OffAyTf3VDTJ3K9B5bJJnqI1malSsBmnTo2T4UDwvbnvr"
        b"FeqbvjmJ9HE5Gt77Ag9UV1yihsbnQIq1FZ2nS4XiZsrnFohz/3BwB7XBNNrTCsUVOnQxOY5n7MZg7EcmIeMBGU4T"
        b"pHswfor+SHIapPSeQ8O/iXmgm5mhhk5+CbbpH5ChkCD2ahj7BQu82lUvuViwzAMf3JuhRh8eAumdT8g7JWscoDDO"
        b"7ng5MWimzrrm9l/NPVWf2famexxBnP8Crt6vvg=="
    ),
    "uwb": (
        b"eNqlVG1Mk1cYbQuiMFsGCrRQbAMqdSUtiBPawoU4tHObXKpAgAkJgcJMttrZFkmGGx8rLR+yzboxp/XOdZrgXOJG"
        b"IFDIphKnWFpDHCRNwFFd+ZCGBF2iLprtvoVBb+HfbtL0Tc97znPu85ynsKrqEI1BWzpTs0XvU98vshoX6LmH1Epl"
        b"DZ/PTxbtFCXTyEPHn1zq4QTNSw9c+u0ffOoYK+/4HkjVovnWot4Y/0kkpPPZ+GmvqvxohbKCf/yI9j3+YvHl0l5u"
        b"YNa5FS5VRJchOpUV+z8PO6/5VZrEoVYfnhQEBu/LgRe7+Wd79mQFy/56/S12nnEm/eKb+zNGC8t+2939h8C1I9nU"
        b"RKMFp1WwGzE4K9/+uBts5l1GnBoeNHY+XATL2sox+Kh2/4IOxH8pRQEaPWzrd5BgpsoN1n3ejsJtT2CrTOUDNkfX"
        b"Mp06wJ2WIpamS0jvw0x63X9Mz4AsSQfiXFbE0JhhvXKQlI0R20HidAjiVJdAQ7+IlI1wYCaWDdeYO+r7CEOegQKO"
        b"DvC+sCL6R2bYrpwlmRLM3OI1ZO4wnsTMpI0rNbPkTaWpHVLE+cEMjW4naUgyrwNbvYaKcBN2r5bFhgooWYPE6Svr"
        b"GcgQ6gE/lYXCDt+EbdOitTsUpjEL10u8HTqyXLNoJALw6gFi2CagYbyINCQT2QF3TurtUNvo4JqGqA7Beqp9Scsg"
        b"d4ACefieLJsZ1vU98AWja5UOypBMzKGY5Mjmvt7heAmEphto/d9maGiSrDbEn6ZigkH9KkPVpZQh1u2JxZEl+TC3"
        b"SzJAUHo7YkemwFaJYzUzBBsKfYXqrZe50qFsqAdBrgeIodbDeolfzf0OamSYuWmJSfNhZopPgK1Jv+CY3IP6a2ry"
        b"KqzGWMDw3EeMTV2wpT9nrQzJxNSwG/qIDM0WFlzvBkEeKwplyaGB6ZchedoBb+KjqVDr/RJfoYoF245PoUjHXhww"
        b"EQlm4JrrTJUozBYrcFe99MuQQzfYlWxFTI1ZPXnSTzb7wM3Bb899hSJDygXuF2O+TE7hBw6t5VyCVDGqxgFrJWrO"
        b"ysXP7CC+o8V1p9gEW577brZxzhD7th7woliK244oaPxTRTKZCfkgztOuGNrwGWxK85MVZurATo9VceugCxqILWvm"
        b"yKUP7NQ6uMbUC7BBQqRvMkH8PP3HU6ZLirFiU6874RkpWxTFtXQ8lSqGfsYZUhIZijGkFTOptXc5Gy90GMk/jFn5"
        b"G5naLTHcyWDbjbtQ7/QzFKiyg7in2JDdDNv6fieZ2jQd4FeXKu4cwx06M0yCibZ8sCGl0jXSEyqk9+aQspLBjZbz"
        b"Ud4tE0xPlZMj+9hpHzz9TRziHLogcOXJSXDbJ3mW079a0eZjc4KHndVkEgpVWktDaiViqSfUM2kqkvlunBZ36Dxi"
        b"SU2CyYkhEsx3ai3tVy6jMG0JbFaeIa+SlRsBgrhWhbMgX0izXiLBsppAy5XeEBRQ/aFgxpJJyhaquJarV6dQBHtC"
        b"4Pr+EQmqJVqL/h3sltMlcIvnyasocTTPR0lRqA2H2nmLZNYeHba0x3+HouxP1O7OXctgrGqEsy/j3rDlvq6Ceb3k"
        b"YKKmM+JsD412RvaYw8RgUpxYdDd7nofmw9njr6V0Rph6Aq4Fy8p3ffov0C8TgQ=="
    ),
}


def tone(band):
    return decompress(b64decode(TONES[band]))
