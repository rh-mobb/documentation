/**
 * OpenShift Network Calculator (OVN-Kubernetes)
 * Client-side calculation functions for network sizing
 */

/**
 * Parse CIDR notation and return network address and prefix length
 */
function parseCIDR(cidr) {
    const parts = cidr.split('/');
    if (parts.length !== 2) {
        throw new Error(`Invalid CIDR format: ${cidr}`);
    }

    const ip = parts[0];
    const prefix = parseInt(parts[1], 10);

    if (isNaN(prefix) || prefix < 0 || prefix > 32) {
        throw new Error(`Invalid prefix length: ${prefix}`);
    }

    const ipParts = ip.split('.').map(p => parseInt(p, 10));
    if (ipParts.length !== 4 || ipParts.some(p => isNaN(p) || p < 0 || p > 255)) {
        throw new Error(`Invalid IP address: ${ip}`);
    }

    return {
        ip: ipParts,
        prefix: prefix
    };
}

/**
 * Convert IP address array to integer
 */
function ipToInt(ip) {
    return (ip[0] << 24) + (ip[1] << 16) + (ip[2] << 8) + ip[3];
}

/**
 * Convert integer to IP address array
 */
function intToIp(int) {
    return [
        (int >>> 24) & 0xFF,
        (int >>> 16) & 0xFF,
        (int >>> 8) & 0xFF,
        int & 0xFF
    ];
}

/**
 * Calculate the number of usable IPs in a CIDR block
 */
function countIPs(cidr) {
    const parsed = parseCIDR(cidr);
    const totalIPs = Math.pow(2, 32 - parsed.prefix);
    // Subtract 2 for network and broadcast addresses
    return totalIPs - 2;
}

/**
 * Split a subnet into smaller subnets based on host prefix length
 */
function splitSubnet(subnet, prefixLength) {
    const parsed = parseCIDR(subnet);

    if (prefixLength < parsed.prefix || prefixLength > 32) {
        throw new Error(`Invalid prefix length: ${prefixLength} for subnet ${subnet}`);
    }

    // Calculate number of subnets: 2^(prefixLength - originalPrefix)
    const subnetCount = Math.pow(2, prefixLength - parsed.prefix);
    // Step size is the number of IPs in each subnet of the original prefix
    const stepSize = Math.pow(2, 32 - parsed.prefix);
    const baseIP = ipToInt(parsed.ip);

    const subnets = [];
    for (let i = 0; i < subnetCount; i++) {
        // Calculate the new IP by adding i * stepSize to the base IP
        const newIPInt = baseIP + (i * stepSize);
        const subnetIP = intToIp(newIPInt);
        subnets.push({
            ip: subnetIP.join('.'),
            prefix: prefixLength
        });
    }

    return subnets;
}

/**
 * Check if two CIDR blocks overlap
 */
function cidrOverlaps(cidr1, cidr2) {
    const parsed1 = parseCIDR(cidr1);
    const parsed2 = parseCIDR(cidr2);

    const ip1 = ipToInt(parsed1.ip);
    const ip2 = ipToInt(parsed2.ip);

    const mask1 = (0xFFFFFFFF << (32 - parsed1.prefix)) >>> 0;
    const mask2 = (0xFFFFFFFF << (32 - parsed2.prefix)) >>> 0;

    const network1 = ip1 & mask1;
    const network2 = ip2 & mask2;

    // Check if network1 contains network2 or vice versa
    const network1End = network1 + Math.pow(2, 32 - parsed1.prefix) - 1;
    const network2End = network2 + Math.pow(2, 32 - parsed2.prefix) - 1;

    return (network1 <= network2 && network2 <= network1End) ||
           (network2 <= network1 && network1 <= network2End);
}

/**
 * Check if any CIDR blocks overlap
 */
function checkCIDRConflict(...cidrs) {
    const validCIDRs = cidrs.filter(cidr => cidr && cidr.trim() !== '');

    for (let i = 0; i < validCIDRs.length; i++) {
        for (let j = i + 1; j < validCIDRs.length; j++) {
            if (cidrOverlaps(validCIDRs[i], validCIDRs[j])) {
                return true;
            }
        }
    }

    return false;
}

/**
 * Validate CIDR format
 */
function isValidCIDR(cidr) {
    try {
        parseCIDR(cidr);
        return true;
    } catch (e) {
        return false;
    }
}

/**
 * Validate host prefix
 */
function isValidHostPrefix(prefix) {
    const p = parseInt(prefix, 10);
    return !isNaN(p) && p >= 1 && p <= 32;
}

/**
 * Calculate OpenShift network sizing for OVN-Kubernetes CNI
 */
function calculateNetwork(hostPrefix, clusterNetwork, serviceNetwork, machineNetwork) {
    // Validate inputs
    if (!isValidHostPrefix(hostPrefix)) {
        throw new Error('Invalid host prefix. Must be between 1 and 32.');
    }

    const networks = [clusterNetwork, serviceNetwork, machineNetwork];
    for (const network of networks) {
        if (!isValidCIDR(network)) {
            throw new Error(`Invalid network CIDR: ${network}`);
        }
    }

    // Calculate number of pods
    const numPods = countIPs(clusterNetwork);

    // Calculate number of nodes based on host prefix
    const subnets = splitSubnet(clusterNetwork, parseInt(hostPrefix, 10));
    const numNodes = subnets.length;

    if (numNodes === 0) {
        throw new Error('Number of nodes is 0. Check host prefix and cluster network.');
    }

    // Calculate pods per node (OVN-Kubernetes uses 3 reserved IPs per node)
    const totalPodsPerNode = Math.floor(numPods / numNodes);
    const podsPerNode = totalPodsPerNode - 3;

    // Calculate number of services
    const numServices = countIPs(serviceNetwork);

    // Calculate machine network nodes
    const machineNetworkNodes = countIPs(machineNetwork);

    // OVN-specific conflict checks (includes join switch and transit switch)
    const joinSwitch = '100.64.0.0/16';
    const transitSwitch = '100.88.0.0/16';
    const conflicts = checkCIDRConflict(
        clusterNetwork,
        serviceNetwork,
        machineNetwork,
        joinSwitch,
        transitSwitch
    );

    return {
        'pod-network': clusterNetwork,
        'service-network': serviceNetwork,
        'machine-network': machineNetwork,
        'cni': 'ovn-kubernetes',
        'number-of-pods': numPods,
        'number-of-services': numServices,
        'number-of-nodes': {
            'want': numNodes,
            'have': machineNetworkNodes
        },
        'pods-per-node': podsPerNode,
        'network-conflict': conflicts
    };
}
