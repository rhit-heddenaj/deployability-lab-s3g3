# Manage Service Interactions: a mediator between old FTP clients and the new server.
#
# Problem (see the v5 change in handlers/ftp/dispatchers.py): the server now answers
# passive-mode requests with the modern "229 ... (|||port|)" reply. Clients built
# before that, such as the M0 JFTP, send PASV and wait for the legacy
# "227 ... (h1,h2,h3,h4,p1,p2)" reply, and hang without it.
#
# Tactic: keep the server's internals on the new contract and translate at the edge.
# The command itself tells us which dialect the client speaks. PASV is the legacy
# dialect, EPSV is the modern one. So we only rewrite replies to PASV; EPSV clients
# are untouched. No per-client version flag or registry is needed.
#
# This is deliberately one small, separately testable class instead of edits spread
# through the handler, so the compatibility promise lives in one place that a test
# and a code reviewer can point at.

from .handlers import FTPHandler


def to_legacy_227(reply, local_ip):
    """Translate "229 ... (|||port|)" into "227 ... (h1,h2,h3,h4,p1,p2)."

    Returns the reply unchanged if it is not a 229 we know how to translate.
    """
    if not reply.startswith("229 "):
        return reply
    try:
        port = int(reply[reply.index("(|||") + 4 : reply.index("|)")])
    except ValueError:
        return reply
    if local_ip.startswith("::ffff:"):
        # IPv4-mapped IPv6 address, e.g. ::ffff:151.12.5.65 -> 151.12.5.65
        local_ip = local_ip[7:]
    return "227 Entering passive mode ({},{},{}).".format(
        local_ip.replace(".", ","), port // 256, port % 256
    )


class LegacyPasvHandler(FTPHandler):
    """FTPHandler that keeps pre-v5 clients working.

    Replies to PASV are translated back to the legacy 227 format; everything else,
    including EPSV, uses the server's new behaviour unchanged.
    """

    _mediating_pasv = False

    def ftp_PASV(self, line):
        # The 229 reply is produced synchronously inside super().ftp_PASV() (see
        # PassiveDTP.__init__), so a flag held for the duration of the call is
        # enough to know that the reply we are about to send answers a PASV.
        self._mediating_pasv = True
        try:
            super().ftp_PASV(line)
        finally:
            self._mediating_pasv = False

    def respond(self, resp, logfun=None):
        if self._mediating_pasv and resp.startswith("229 "):
            ip = (
                self.masquerade_address_map.get(self.socket.getsockname()[0])
                or self.masquerade_address
                or self.socket.getsockname()[0]
            )
            resp = to_legacy_227(resp, ip)
        if logfun is None:
            return super().respond(resp)
        return super().respond(resp, logfun=logfun)
