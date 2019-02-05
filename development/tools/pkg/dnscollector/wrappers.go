package dnscollector

import (
	"context"

	compute "google.golang.org/api/compute/v1"
	dns "google.golang.org/api/dns/v1"
)

//ComputeServiceWrapper A wrapper for compute API service.
type ComputeServiceWrapper struct {
	Context context.Context
	Compute *compute.Service
}

//DNSServiceWrapper A wrapper for dns API service.
type DNSServiceWrapper struct {
	Context context.Context
	DNS     *dns.Service
}

func (csw *ComputeServiceWrapper) lookupIPAddresses(project string, region string) ([]*compute.Address, error) {
	var items = []*compute.Address{}
	call := csw.Compute.Addresses.List(project, region)
	call = call.Filter("status: RESERVED")
	//call = call.Filter("creationTimestamp > 2018-11-09T05:01:51.510-08:00") <- probably can't be done. Filtering in memory.
	f := func(page *compute.AddressList) error {
		for _, v := range page.Items {
			items = append(items, v)
		}
		return nil
	}

	if err := call.Pages(csw.Context, f); err != nil {
		return nil, err
	}
	return items, nil
}

func (csw *ComputeServiceWrapper) deleteIPAddress(project string, region string, address string) error {
	_, err := csw.Compute.Addresses.Delete(project, region, address).Do()
	if err != nil {
		return err
	}
	return nil
}

func (dsw *DNSServiceWrapper) lookupDNSRecords(project string, managedZone string) ([]*dns.ResourceRecordSet, error) {
	call := dsw.DNS.ResourceRecordSets.List(project, managedZone)

	var items = []*dns.ResourceRecordSet{}
	f := func(page *dns.ResourceRecordSetsListResponse) error {
		for _, v := range page.Rrsets {
			items = append(items, v)
		}
		return nil
	}

	if err := call.Pages(dsw.Context, f); err != nil {
		return nil, err
	}
	return items, nil
}

func (dsw *DNSServiceWrapper) deleteDNSRecords(project string, managedZone string, recordToDelete *dns.ResourceRecordSet) error {
	change := &dns.Change{
		Deletions: []*dns.ResourceRecordSet{recordToDelete},
	}

	_, err := dsw.DNS.Changes.Create(project, managedZone, change).Context(dsw.Context).Do()
	if err != nil {
		return err
	}

	return nil
}
