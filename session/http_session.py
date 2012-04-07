

import cgi, sys, urllib, urllib2
from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer

from simple import SimpleStreamingSession

def post(url, data, read=False):
    """
    POST the dictionary of data to the url.  If read=True return the
    response from the server.
    """
    r = urllib2.urlopen(urllib2.Request(url, urllib.urlencode(data)))
    if read:
        return r.read()
    
##############################
# compute session object
##############################

class ComputeSession(object):
    def __init__(self, port, frontend_url, output_url):
        class Handler(BaseHTTPRequestHandler):
            session = self
            def do_POST(self):
                try:
                    ctype, pdict = cgi.parse_header(self.headers.getheader('content-type'))
                    if ctype == 'application/x-www-form-urlencoded':
                        length = int(self.headers.getheader('content-length'))
                        postvars = cgi.parse_qs(self.rfile.read(length), keep_blank_values=1)
                    else:
                        postvars = {}
                    Handler.session._postvars = postvars
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write('ok')
                except IOError:
                    self.send_error(404,'File Not Found: %s' % self.path)
        self._port = port
        self._frontend_url = frontend_url
        self._output_url = output_url
        self._server = HTTPServer(('', port), Handler)
        self._session = SimpleStreamingSession(0, lambda msg: self.output(msg))

    def run(self):
        while True:
            print "waiting to handle a request on port %s"%self._port
            self._server.handle_request()
            print self._postvars
            if self._postvars.has_key('code'):
                # the request resulted in a POST request with code to execute
                code = self._postvars['code'][0]
                print "code = ", code
                self._session.execute(code)
                # done
                urllib2.urlopen(self._frontend_url)

    def output(self, msg):
        post(self._output_url, msg)
            

        


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print "Usage: %s port FRONTEND_URL OUTPUT_URL"%sys.argv[0]
        sys.exit(1)
    port = int(sys.argv[1])
    frontend_url = sys.argv[2]
    output_url = sys.argv[3]
    S = ComputeSession(5100, frontend_url, output_url)
    S.run()
    
