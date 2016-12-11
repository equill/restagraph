#!/usr/bin/python3

# Test package for Restagraph's REST API.
#
# Written in Python because that's the language I expect most users to implement
# their code in.
# Using Python3 because it's about time we all moved forward, and Docker means
# we no longer need to stick with obsolete stuff.


# Included batteries
import unittest

# Third-party libraries
import requests


# Config variables
PROTOCOL = 'http'
SERVER_URL = 'localhost:4950'
PREFIX = '/api/v1'

BASE_URL = '%s://%s%s' % (PROTOCOL, SERVER_URL, PREFIX)


# Tests

class TestResources(unittest.TestCase):
    '''
    Basic CRD functions for resources
    '''
    routertype = 'routers'
    routername = 'amchitka'
    routercomment = 'Test router 1'
    def test_create_and_delete_single_resource(self):
        # Ensure it's not already present
        self.assertEqual(requests.get('%s/%s/%s' % (BASE_URL, self.routertype, self.routername)).status_code,
                404)
        # Create it
        self.assertEqual(
                requests.post('%s/%s' % (BASE_URL, self.routertype), data={'uid': self.routername, 'comment': self.routercomment}).status_code,
                201)
        # Confirm that it's now there
        self.assertEqual(requests.get('%s/%s/%s' % (BASE_URL, self.routertype, self.routername)).json(),
                { 'uid': self.routername, 'comment': self.routercomment })
        # Delete it
        self.assertEqual(
                requests.delete('%s/%s' % (BASE_URL, self.routertype), data={'uid': self.routername}).status_code,
                200)
        # Confirm it's gone
        self.assertEqual(requests.get('%s/%s/%s' % (BASE_URL, self.routertype, self.routername)).status_code,
                404)

class TestRelationships(unittest.TestCase):
    '''
    Basic CRD functions for relationships
    '''
    routertype = 'routers'
    routername = 'bikini'
    routercomment = 'Test router 2'
    interfacetype = 'interfaces'
    interfacename = 'ge-0/0/0'
    rel_router_interface = 'Interfaces'
    def test_basic_relationship(self):
        # Create two new resources
        self.assertEqual(requests.post('%s/%s' % (BASE_URL, self.routertype), data={'uid': self.routername, 'comment': self.routercomment}).status_code,
                201)
        self.assertEqual(requests.post('%s/%s' % (BASE_URL, self.interfacetype), data={'uid': self.interfacename}).status_code,
                201)
        # Create a relationship between them
        self.assertEqual(requests.post('%s/%s/%s/%s'% (BASE_URL, self.routertype, self.routername, self.rel_router_interface), data={'to-type': self.interfacetype, 'to-uid': self.interfacename}).status_code,
                201)
        # Confirm that the relationship is there
        self.assertEqual(requests.get('%s/%s/%s/%s' % (BASE_URL, self.routertype, self.routername, self.rel_router_interface)).status_code,
                200)
        self.assertEqual(requests.get('%s/%s/%s/%s' % (BASE_URL, self.routertype, self.routername, self.rel_router_interface)).json(),
                [{"resource-type": self.interfacetype, "uid": self.interfacename}])
        # Delete the relationship
        self.assertEqual(requests.delete('%s/%s/%s/%s'% (BASE_URL, self.routertype, self.routername, self.rel_router_interface), data={'to-type': self.interfacetype, 'to-uid': self.interfacename}).status_code,
                200)
        # Confirm the relationship is gone
        self.assertEqual(requests.get('%s/%s/%s/%s' % (BASE_URL, self.routertype, self.routername, self.rel_router_interface)).status_code, 404)
        # Delete the resources
        self.assertEqual(requests.delete('%s/%s' % (BASE_URL, self.routertype), data={'uid': self.routername}).status_code,
                200)
        self.assertEqual(requests.delete('%s/%s' % (BASE_URL, self.interfacetype), data={'uid': self.interfacename}).status_code,
                200)

# Make it happen
if __name__ == '__main__':
    unittest.main()