#!/bin/bash
#
# SwiftBar plugin — AWS session indicator
#
# Shows whether an `aws login` session is currently active on this Mac:
#
#   green cloud   session active
#   red cloud     session dead — time to run `aws login` again
#   grey cloud    never logged in, or the AWS CLI isn't installed
#
#   There is deliberately no "expiring soon" state. The credentials in the
#   cache last only 15 minutes and the CLI refreshes them automatically for up
#   to 12 hours, so a countdown against that timestamp would warn every quarter
#   hour and mean nothing. Green means refresh is working; red means it isn't
#   and you are locked out until you log in again.
#
# INSTALL
#   1. Get SwiftBar if you don't have it:  brew install --cask swiftbar
#      (or https://swiftbar.app). On first launch it asks you to choose a
#      plugin folder — any folder will do, e.g. ~/.config/swiftbar/plugins
#      You can see it later under SwiftBar → Preferences → Plugin Folder.
#   2. Save this file into that folder, keeping the name aws-session.5s.sh.
#      The ".5s." is the refresh interval and SwiftBar reads it from the
#      filename, so don't let a browser rename it to .txt or strip that part.
#   3. chmod +x aws-session.5s.sh
#      (SwiftBar normally does this for you, so it may already be done.)
#   4. The cloud shows up in your menu bar within a few seconds.
#
# REQUIRES
#   awscli >= 2.36, i.e. one that has `aws login`, and you need to have run
#   `aws login` at least once. Nothing else — no Python, no Homebrew packages.
#   Works on Apple Silicon and Intel.
#
# PRIVACY
#   Reads only `expiresAt` and `accountId` from ~/.aws/login/cache/*.json.
#   The credentials and refresh token in that same file are never read,
#   printed or logged.
#
# HOW IT DECIDES
#   Every tick it reads the cached expiry — instant, offline, no API calls.
#   Only once that expiry has passed does it spend one
#   `aws sts get-caller-identity` to tell "refreshable" apart from "logged
#   out", and that probe is rate limited to once a minute.
#
#   Note that probe is also what triggers the CLI's own refresh, so leaving
#   this plugin running keeps your credentials rolling. It cannot extend the
#   12-hour session cap — nothing can — it just means the cache stays warm.
#
# <swiftbar.title>AWS Session</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Shows whether an `aws login` session is active locally, and lets you re-authenticate.</swiftbar.desc>
# <swiftbar.dependencies>awscli</swiftbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

# GUI launchers give a bare PATH. Cover Homebrew on both architectures.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# All overridable, which is also how the test fixtures drive each state.
AWS_LOGIN_CACHE_DIR="${AWS_LOGIN_CACHE_DIR:-$HOME/.aws/login/cache}"
AWS_SESSION_CONFIG="${AWS_SESSION_CONFIG:-$HOME/.aws/config}"
PROBE_STAMP="${AWS_SESSION_PROBE_STAMP:-${TMPDIR:-/tmp}/aws-session-probe.$(id -u)}"

PROBE_TTL=60      # min seconds between live probes while the cache reads stale

# Absolute path to this file, so the dropdown can call back into it.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --- icons (generated; see gen-icons.sh / build.sh) --------------------------
ICON_ACTIVE="iVBORw0KGgoAAAANSUhEUgAAADwAAAA8CAYAAAA6/NlyAAAAAXNSR0IArs4c6QAAAHhlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAADwAAAAAQAAAPAAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAADygAwAEAAAAAQAAADwAAAAA6Q45SAAAAAlwSFlzAAAk6QAAJOkBUCTn+AAABGhJREFUaAXtmV+IVFUcx3+/+2fWcbZlSUstkLCxLdf1OjuCBBH7VBikFA27qw/1ZFFhEgQ9hU/1VlTUW+mTuzVF5UL0EEYGUrQ6+8dJRQh80iBblWLbnXvO8XdWkDn3z8y9d+6Mc5d7n+4553vO7/v5zcz5NwDpk2YgzUCagTQDaQa6JgPYaSelL0v6n1t67l/O8KyMnVmuXTuzq3yjUz7aDjzy04hxvX/j06CJZwDwSQJ7RHI6AP8hIzMCxEkO/Ks5q3zR0R5bsW3AAxf23pNdyr1OEIcoyMZwjvGUBvDeWWvih3D9mqvbAlyYHXtBAHxI4R9obqGRQnyPTH+1Mnz8ciNVmLZYgQerpYxZ0z8GhINhTDTRLnDAF+esiakmukDNsQEXp59dyzK5b0DAU4EihxMxMvpyxZr8LFw3tzoW4OL0QZOZN76lSYkmprY9HEEcqFhfTLYSgeaG1h9m3ny3zbDSpEZf7aPWzFihFcctf8I7K2MjoMFJMtHyWIFAEP+o6XahOlheDqR3iFr6hOUmAnT8pGOw0rwQ20xbP+TgCFxsCfjSo/qoNBA4WnzCt2lF6I0yXEvANCNHznQUs3V91plMH68rB36NDDxcLeUpyu7AkeIX7o8yZGRgbhvtWG+DMwh4Qm5fg3e4rYwMDCgeDxssZr2RXVxbDDtmdGCAgbDB4tYLxNAejKAmaFa817SN5xH4XgG4g9aHzZ1aev08asA3+LX51TcFlntkO5N7Exm8RZB9BHt7LNGZfYafcVlPJ7Jco3avtobA1kzpQYb6dygg9G/FK1jsdYiLYcf0BR6a278FBT9NA4b+2oQ1EVUvUPwdtq/n93L3rwf6lrJMwg6GHbCTerpNmULEKRvxxLmhib+CxPYE3jk7+gFNSIeDDNAlGpt8HDUN9s7vg+WrjTy5gOn08xCdfi5Qp55GHbuyDeEKF/DcnDX5m58/9zqswUskTh6sJBSwiYB+HJ4fp2XT+3EDg9jnLU1MbS9n4uv8pT2eH5oCLK9q6Lfrm53EICPkc//1veblVwFe6rkp74+VOq9OSaij2fsVL58KnFljoU8fXoN2Sd3W4vzow04vCvByDzSc0p2du71sM5F3elSAq9vKCyT41ylKahk1bZ3TuwJM5wI6ceEppyipZQ253JAojwpMTYLxjKJIcIEL3OO0rwCvXLtqaDlFiS1LYHFEYVQK5x/T5b999yUW0G18gzVb3VRfrQCvsmVphVPXtT5fYNswr9Q3roJ3we2swqR8wvM7ji/QBnx2FYCuINBRsDJTOHa9nkcBXmnQ4NN6QcLfXSwu4P5rVz+nzPyScFBp/+f8RXbMyeG6AJCC4vT4emaKE/R6ty/bnX6DlQWc1m3cd2bXhOvOyxNYjirPk72L/W/QVuSwPFgHi3SXVXTjQV7frxnsI7//j32B71inhbtQPT/EmLaZtmpr7tR30QsX2v+GBpfPbh84B3iEd5G11EqagTQDaQbSDKQZSDOQZiDNwOrNwC1DBgthWB3grQAAAABJRU5ErkJggg=="
ICON_EXPIRED="iVBORw0KGgoAAAANSUhEUgAAADwAAAA8CAYAAAA6/NlyAAAAAXNSR0IArs4c6QAAAHhlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAADwAAAAAQAAAPAAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAADygAwAEAAAAAQAAADwAAAAA6Q45SAAAAAlwSFlzAAAk6QAAJOkBUCTn+AAABCNJREFUaAXtmV1sDFEUx8+ZXdv6aqX1LRGhSDSI9KG2SuojZSUI0QgeeEKQRiTCk/SJRxHhzcejBPEVQkNTRZtGBAnCYxNJSbAqorXdmePMNGHv3enu3NnZ7U4zk0w6d+7/fPzOnZl7excgOIIKBBUIKhBUIKhA0VQAC50JNTWF4OfnqaDT2KHY/d/w0cu+QuWRd2BqaAhDOLGegTYCwir+u4DPiAT4nduvgaANwngdHzz/KPV71swbMG1eMREG4DBn2gxE0xUz7gCDTuPjrgeKdlnleQGmxrrtPFpnOfrMrBlkFtwHHQ5iW2dPZpnzXk+Bqak6AvHyc/zo7nOeQlZlHFDbg63P7mZVOhB4BkybasbBQMlNjtnoIK6qRAfE/dj6/KKqoaz3BJhqasZARcktdr5RDuBh2+AnZze2dl7NxaeWi/E/28rSU3ydT1gzlMbfhcu0LrrsX1wXFzmPMK2rbwA02jh2zr6c5U/vYdLPZXjtXcKZXlTlNMLWIgL184WDNZPHRRAvaxYxnLdyAob4px1WAs7jeaNEPMELmglunOUGjLyoGJmjkldvO92Edg1M66NVPLq1boJ6YoO0y40f18BAmI/5VoEB663lq4KFKc0BGKKKsbyWh+E31qg6dQ8MsFA1mOd61JVzCDtNgt/ZCjC0bQDGZn53l7DdbKe2+dNp01R9ZwW21sh/So6CAccAqIxhVWPkUU/jVZ1nBKY10VkwgLfZqfK7opqIKz1Cv6rdsMC8ZJzLS8ZOdqj82Kgm4Vpv4FdVW9vnk2K1ZZAMmbDVqg4Lq8e7vJvCp34HH3d/cRLbHrhxxRl2dMSJgyLRJPnTchkSgyex/cXnTDmlAdOG5XNA1z6wUUkmwyLt6+Xdka28O9I9XH7p87Ch7WWxH2FNxhlAxiNaW2tOm7ZHOjDBFltlUd2kTNlMAC10g2Ix20ETgK2tGoBhq5MpSmH70t5EOXwVJPsOyTfNtgAMlePN/WPxnp2VP+4dsEtThNNpop3Ip/fm05q6eXLuInA4mfGTLhsXfVujKjlHEfhhV5wFv2SRj9uVcu4CMH8KzM9fhyzybVunpJy7AGx1EkZkkW/bYS0m5y4AD2270lJZ5ON2jFrEWUcAhr4v5q99U3wMKKc+DTqiM1JvisCja1oa4tTMTYv/hwhcSr3/u0bFFUGyVGASgPHeM3NaejMqUE0IglfY3v4jlUcAtjoQLqQKfH2tYRpLOnAicokr89TXoEPJP4HymVdkDtt/O/iHqskQSdxh8JHebJfzddruhMHIFn6c0/a80keYXVrCUPlqvjzOp/DSO404Qrpe3po6BpP6VtvBmjnZjnBqstbE3VW/mEd7Nm+Wlab2Fc01hgZAH+yBld1vsYV30IMjqEBQgaACQQWCCgQVCCoQVCCoQP4r8BcxVu6Wkg93twAAAABJRU5ErkJggg=="
ICON_NONE="iVBORw0KGgoAAAANSUhEUgAAADwAAAA8CAYAAAA6/NlyAAAAAXNSR0IArs4c6QAAAHhlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAADwAAAAAQAAAPAAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAADygAwAEAAAAAQAAADwAAAAA6Q45SAAAAAlwSFlzAAAk6QAAJOkBUCTn+AAABF1JREFUaAXtmktoFEkYx7t62vaZCSRodFdE3KigqIgHEUT04qIHRZGI7mE9GTFRJk3UeJGclAhO68hEcvBxlLDiIyAeRFAh4kkFkfUoGuIjahJGTTI9Vf5LmZDq6Uy6umeSnqHr0v1VfVXf//f1o6prRlHCEmYgzECYgTADYQYCkwEy2Uo6OzsjPT098xRl+kwee3g48rmlpX5gsnQUHbi1tVWrrKz6mzGynTFlEyHKMsDpNsAvsJ+j/UEkkvkvFou9trUXzCwacFtbW4WmzW4khB2F2vkyigH+iBD1jGE03JPp58a3KMCmmdijKOQChP/hRkQen7uUksPNzY1v8vhINRUUGLevHo1WX4SCg1Iq8jjjEfjKGPvXMI525XFz3VQw4I6Ojlnfvo3cROStrqO7d8zAtd4wjlx238XZsyDAgJ0G2FsIsd05TEFqKR6Tfwyj8bqf0VQ/nbN9U6mR0zgvJiwPBa3s6rlzibXZuF6Ovq+waV7czKcTBPc9lkuAV4ODn9fifTHi0l9w83WF+SICsMlJhOXiV1RWVvOpzlPxBfzu3Ye9iLrCU2QfnZDklmQyOcfLEL6AEdBzpr2IHdOnemgos2+M7frUM3A8nqxFlPWuIxXYkRCy38uQnoEVhRZjvpVh2MiXrzIduK8PYGWDbLAC+2u6Pmud7JiegbHcWy4brND+lMpr0NyKiMfjVYTou/GG3IEFwGqscRfhfEoLvqhqZAVMCPx7jTxsYF1xDFc1mg0w1bBcB/TMzupxe8wLHI9f+vP79/RtwEo/K24F+PT7Idt/XGDTbF/CmNWNKyl928iK8OqPzYU+2b6O699EIhG1LNKNwVbKDji5/qwLF6QrEqF3sC30wU1sR2DsWJjYg4q5GSAgPhZ0XLUs9dTx4w3v82nKATZNczFj2v/oND1fx4C29aoq2RWLNT4dT1/OPEypdgDOrmCD8Ka2gS3A3Hz//Pn21bb6UTMHGPPrztHWCU7gG8Qyh9LMDbyHHC+aAMy3akAwbnaCSDeOptp0Wm1wahOAUymL7x8LdU6dSqEOU9YhJ50CHGMZ6a8Pp0EDUrf07NnEX3YtArCqWnlf6fbOQbd1ndTaNQrATU1NX+GQsjuVqk2pUm3XLgBjFwHrcfLI7lSqdiZD+YJEKAIwb2GM6oJHCRtYhGyzyxeA+bYrnNbYnUrVxh27DfvXAqNgvH37if/aN7dUAR1010SjNQvG1gvAZTYt/eIkhI5uWvAKATid1nrHZqMMzrEJNSIwCcAnTx7m09KLMgDNIjzDVNufNfhRAOYVeNDb+bFMSg5LDvDAQN8VwD4uA+CHCxfWXLNz5ADjNW5Rqu+G4xO7c+nYpBsMe+rq6vg/B4SSA8xbm5vr+zSNbcH37gmYwkMv9A6e0QvNxwYH+7ZwBid5E37C84m7oqJqFQbCxjuZ4TTIVNdhRTykqtqb/v6PL6EXf40IS5iBMANhBsIMhBkIMxBmIMxAmIGiZ+An/RMt4W2PtcwAAAAASUVORK5CYII="
ICON_LOGIN="iVBORw0KGgoAAAANSUhEUgAAAFgAAABYCAYAAABxlTA0AAAAAXNSR0IArs4c6QAAAHhlWElmTU0AKgAAAAgABAEaAAUAAAABAAAAPgEbAAUAAAABAAAARgEoAAMAAAABAAIAAIdpAAQAAAABAAAATgAAAAAAAAFgAAAAAQAAAWAAAAABAAOgAQADAAAAAQABAACgAgAEAAAAAQAAAFigAwAEAAAAAQAAAFgAAAAAG3Zv6wAAAAlwSFlzAAA2IgAANiIB7Ob98wAACiNJREFUeAHtnX1wG8UVwN+eJFuS7dhJnDhpSAyU4GIntpykoTAhdaFlCkNoS0hiuw0NnQ6QtEPD0Jn2j0KYzFBg2jHtlGkKw2dbSNyQlkkYkhSYBigM7Rjjj7pxYickfOXDsRV/SjpJt31PiVx/nKSTbu90lvVmNCftvX379qfV3u7b1R0DHVLRsS7fEXasZoqymjOoAGCLAfhcNJmPL4cO0+nIGsRChzjAGQl4l8KkDgmUt2Wb8k5Hxe6hVB1iSWfkwKrbN3yTc+lOhHkr5s9N2sYUyoDA/YzBXomz55ordx4EBpikXZIC7GnbsI5xeAAZL9VeRAZpcmjlwLe3ehr/qrVWmgB7PqxfzCVlByrfoNVwRutxeF1yhLc0V+zuTlTPhICrW+vW4rf2DBoqTGRsep1ng8D4PS2Vu16KV28p5knsBzyttQ8h3JdRJwt3EihegL3xi9UttY/iMWZDVT+BGaraan+PJ++ZZDeboEZgB7bkH6ldAFVbcFV73S+zcNU4xkzbXN1au13t7KQWXNVSuwGHJbvUlLNpCQgw/r2WysYXx2qNA0yjBZCUZlSgiUJWkiXAYMDG+LIPljYei2Yd10XQUAxPZOFG6SR75DAjHGbEcFRGAWMfcjs25+w4dxRNim8YfAO72e9Ec18AHBlm8AejidmjPgLYULdFh24RwJHYwnSd/upjqZ6bQVVV6/ob6WQEMOfsB+qa2dSUCTDbJsrLyjpvLXAF3D34PqOjYlRZk8VnCw4XSy45/zosOAtXPH1XyO5eJVGwXLztrEUiwBirwTgyrURkxSAC5XSRu9Ig49PeLC59lBHg4mlPwiAAOB4utqNty02N3ZITri2ogqvzl8BcxyyY45gJLikX+kL9cDbohW7/J3BooAmO+T81CI0wswUUVE9qEU9Y0SqGSnPnw+aSdfC1whWQwxIvSn8cOA1/7HkVXvEegjAPq1hMf5IlAFPr3Dr/u3DbrOvBzmxJUzkR+Bwe+exZ+PdQR9J5jc6QdsDUBTx+6f1Q7rpcV10VrsATpxvhuZ69uuyIzkx9cNrkkpwSeP6Kh2C2vUi3DxKT4N75dVBkL4DHT42Leeu2rccAjSLSInmSK9JyRcAdW4E75twCa2dZJ+qaNsDbF26GK5wLx7IR9v5nCzbBVa7LhNnTYygtgJfnXQXXF35Zj99x8zqYHX76hY1xdcw6aTpghmvbNGIwWpbhl7iqwGN0MQntmw6YfrpL3F9M6JgIhdtnf12EGV02TAdcg5MIs+Qr+UsjM0CzylMrx3TAZv5sc6UcWInT7XSK6YAX5c4ztb5XOheZWt7EwgyfaNAEYGVeBXy1cDmUOS8FGv+aKXMds80sblJZhgK+bkY13IcjhstyF0wq2KwEF3YT6RRDANNQ7O6StXBXyW34DqOiaRSfEkhj6QCGAN46vx5oymoF6Q+n/P8VIe4Lj6bdULgSfl16nxDnRBn5TD4Lr/f/KxI79oYGRJnVZEfoKIKmqNR6rSYLcubCpjlrYF/Zb4AagJkiFDCtRFAI0qqSZ3PBr0q3ws1Fq0xzUSjgmhnmzdJSJUQX3W0L7wKzxuNCAZc5S1Ott6n5aL1vS8l6U8oUCni2Q//KhCm1xkKoOzNj0iMUcIiHzOKjuxxqxeXuy3XbSWRAKGDaszCVpFjAWmCi+gqdaLSPdFtmqSZRxek8bs7TopZYh+PfNUfCoIwEgcsK8DB+DuELj0IBo8nEzlhIg4JQr3n/mbRHylAIQn1+UPpkUAaDoPhw0wtCVhOhgMststCoVlG1tKsLtN00gNAp5/wQ/NwH4d4AtlLtu4iEAl6EW5+mkszDUKYTdxX5YwSElBFsqZ8MQ/CUD3hAO9SxDIQCDuPumqkk1KXRjqCJQj/74IkhBDuCP/2JZ5P7LBRwl/8k7ojU9rNLzk1jtGlPm8zpTjIXRBkOQeDIAIR7fNEk3Uehw7R93rd1O2SmgX19F/zlCge5exBG3jsjFC7VRSjg/d53oWnov2YySrmsLtxj/FLvgchFy/fOWZCPYRhzcm+Rsv1oRqGAcQQI959ssOQ20miF6djpOwE/Pv4oDB7tBd8HvaD4jZuBCg+4UwUkjFjdWHQNrJm5Ghbjqi4tn6dbZCUI1OceOP8e/O3UmzDU2gOKVzbcLUMAG+61jgLoQuZrOgfcn9qwK9mihY4iki3cbH2lXwZfc29kOmtW2dMGcAhnYoEP+4BGDGbKtAAcPi+Dv6UPRwnmwqUvUugowsyWobUsCsxQt4B/Q9KaRaheRgOmCxld0CBowABX49eQuYCxwfrasM+NE6RZudADFSXG/pM4YwHL3QMJx7lLSsrglTuehhfWN0DlvC9pbJPJqWUkYIrZyh9p3zJ1bekK2LPxKUNAZxxgGob5O3BtMMYKQ7z2ZwRoAmz8fDFerQSfCx4bBE5LODpEGGikS4C1/5Z0OG1GVlqBkE8MCitKN2gbUxAwoxsiZYQEOo0JOaYKmjlsQQTMuzKBrjIQFB4sn8iFQL+88UlouOVBcNgS325BypW8eM8e9p+JhqbiZ/kjcV1DrPr7gn74U/MeeOQfT0Aw/P+lplj6LMd23E6PMsA7K/48ltJUSKe+N3xa3DraxDoT2N3tr8If3v8z9AxjTEOjMKdjr52eE2EP2fy4x8WpMZ/l1IKfDutd/FWtU6pgyRizMQiHh5+x00M4PG21e9FDc/ZzqlZFRyKOd0O4b0Gk6AEb9UMqzDl5pP6Nc5FwJT2EA9fTpiTgyE4bQasTIsBGATO3/Ul6HwFMTzipbqttxvjIsqjCVDnSdia9IhIs+cLy7L7OugOPAf5d5ULAHR8fo7Twh3G34R69zpqdn1pwqjIsj0QuXM82NYLX15+qmUn57DOdDbjuG4mRjtu/ibf4eg21b5qUw6IJFEwfefeMpbyzFeb0Hrn7zeKoUzRVHhXJHr4XG7jxA8rREvW9oS2kVhLmYJzNzFk71qdxgOnZPHhR/uFYBSu/p/25VhLbPPfvOtfvf2usT+MA04lWz86/YCt+eKySVd/TLkiriL3E9RZe2H4y0Z9JgEmhpXLnA3jYMVHZUp/xpxbZWW4Bp+xzcts7v//3GjVXVAHjFZC3VO3agvcWtuwUmv4TkUpQXQ2CnjRsue933vlGZSwb6oAvardW7nqMc46dNj8fy0C60ukPJ+kUuqA5LnH/FlvuNfH8iAuYMtLT/2wSrMBGfTCeIbPP8UB69jlQPW1FuT32Rfk1h+sPbk1U73Hj4ETKnra6b+OUZBteBD2JdI0+H/x4CAKHxU0OtPiL01+ffZaz4XD9/l9o0SedpABHjNKz5ughHMy2CVv1tzDN3JvwRJzAhcTjgyB3GX/vByYxkIpyTlJsITL9vThDu+hGwkPygMeYXN60xk2PMqC77WNyOb5oF0cJvuiu2oZuCpaP9ie1NI/+xBcECfgoLeaQZFqJoGA5xXMp5Hi0/hBuD0pN/gdv91AyZjkRCwAAAABJRU5ErkJggg=="

# --- reading the login cache -------------------------------------------------

# Pulls one string field out of the newest cache file. Only ever called for
# expiresAt and accountId — never for the key material alongside them.
_cache_field() {
  local file
  file="$(ls -t "$AWS_LOGIN_CACHE_DIR"/*.json 2>/dev/null | head -1)"
  [[ -n "$file" && -r "$file" ]] || return 1
  LC_ALL=C sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -1
}

# Epoch seconds of the cached expiry, or non-zero if there isn't one.
_expires_epoch() {
  local raw
  raw="$(_cache_field expiresAt)" || return 1
  [[ -n "$raw" ]] || return 1
  raw="${raw%%.*}"        # drop fractional seconds, if any
  raw="${raw%Z}"          # and the zone marker: the value is always UTC
  raw="${raw%+00:00}"
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$raw" +%s 2>/dev/null
}

# IAM principal from `login_session = <arn>` in ~/.aws/config.
_principal() {
  local arn
  arn="$(sed -n 's/^[[:space:]]*login_session[[:space:]]*=[[:space:]]*//p' \
    "$AWS_SESSION_CONFIG" 2>/dev/null | head -1)"
  [[ -n "$arn" ]] || return 1
  echo "${arn##*/}"
}

# --- live probe (rate limited) -----------------------------------------------

# "ok" or "fail". Only reached once the cached expiry has already passed.
_probe() {
  local now ts cached result
  now="$(date +%s)"
  if [[ -r "$PROBE_STAMP" ]]; then
    read -r ts cached < "$PROBE_STAMP"
    if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < PROBE_TTL )); then
      echo "$cached"
      return
    fi
  fi
  if aws sts get-caller-identity >/dev/null 2>&1; then result=ok; else result=fail; fi
  printf '%s %s\n' "$now" "$result" > "$PROBE_STAMP" 2>/dev/null
  echo "$result"
}

# --- the `Log in` action ------------------------------------------------------

# `aws login` hands off to a browser and can prompt, so give it a real terminal.
# iTerm if it's installed, otherwise Terminal.app, which every Mac has.
_open_login() {
  if [[ -d "/Applications/iTerm.app" ]]; then
    /usr/bin/osascript <<'OSA'
tell application "iTerm"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    write text "aws login"
  end tell
end tell
OSA
  else
    /usr/bin/osascript <<'OSA'
tell application "Terminal"
  activate
  do script "aws login"
end tell
OSA
  fi
}

if [[ "${1:-}" == "login" ]]; then
  _open_login
  # Any cached "fail" is now stale — drop it so the menu bar doesn't stay red
  # for up to a minute after a successful sign-in.
  rm -f "$PROBE_STAMP"
  echo "Opening a terminal — finish the sign-in there."
  exit 0
fi

# --- state --------------------------------------------------------------------

if ! command -v aws >/dev/null 2>&1; then
  echo "| image=$ICON_NONE"
  echo "---"
  echo "AWS CLI not found | color=red"
  echo "Install the AWS CLI (2.36+), then log in with: aws login | color=#888888"
  exit 0
fi

now="$(date +%s)"
expires="$(_expires_epoch)" || expires=""

if [[ -z "$expires" ]]; then
  state=none
elif (( expires > now )); then
  state=active
elif [[ "$(_probe)" == "ok" ]]; then
  # The CLI refreshed under us via the stored refresh token.
  state=active
  refreshed=1
else
  state=expired
fi

# --- menu bar -----------------------------------------------------------------

case "$state" in
  active)  echo "| image=$ICON_ACTIVE" ;;
  expired) echo "| image=$ICON_EXPIRED" ;;
  none)    echo "| image=$ICON_NONE" ;;
esac

echo "---"

# --- dropdown -----------------------------------------------------------------

case "$state" in
  active)  echo "AWS session active | color=green" ;;
  expired) echo "AWS session expired | color=red" ;;
  none)    echo "Not logged in to AWS | color=#888888" ;;
esac

principal="$(_principal || true)"
account="$(_cache_field accountId || true)"
[[ -n "$principal" ]] && echo "${principal} | color=#888888"
[[ -n "$account" ]]   && echo "Account ${account} | color=#888888"

echo "---"

if [[ "$state" == "active" ]]; then
  echo "Log in again… | bash=\"$SELF\" param1=login terminal=false refresh=true image=$ICON_LOGIN"
else
  echo "Log in to AWS… | bash=\"$SELF\" param1=login terminal=false refresh=true image=$ICON_LOGIN"
fi
