# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Ensure that the Verilog and C++ sides of a Verilator simulation are configured
# consistently by building both configurations from a master configuration file.
# The Verilog side should `include the generated Verilog parameters, and the C++
# side is configured by passing a YAML file to the simulator command line.

from argparse import ArgumentParser
from collections.abc import Iterable
from dataclasses import dataclass, field
import yaml


def write_verilog_config(filename, params, config):
    with open(filename, "w") as f:
        f.write("// Generated by tl_config_generator.py\n")
        f.write("// Include this from an appropriate SystemVerilog file.\n")
        for param in params:
            if param not in config:
                print(f"Error: could not find {param} in configuration file.")
                exit(1)
            
            value = config[param]

            # Format the parameter as a Verilog array if it is a sequence.
            if isinstance(value, Iterable):
                value = map(str, value)
                value = "{" + ", ".join(value) + "}"

            f.write(f"`define {param} {value}\n")
    print(f"Wrote Verilog config to {filename}")


def get_parameter(config, name, prefix, default):
    if (prefix + name) in config:       # Most specific, e.g. HostDataWidth
        return config[prefix + name]
    elif name in config:                # Less specific, e.g. DataWidth
        return config[name]
    else:
        return default


def parse_verilog_int(string):
    """Convert a string representing a Verilog literal into an integer."""
    # The format we have is e.g. 3'd4.
    # The 3' represents the number of bits, and is optional.
    # d represents the encoding (d for decimal, b for binary, h for hex).
    width_removed = string.split("'")[-1]
    encoding, value = width_removed[0], width_removed[1:]

    if encoding == 'b':
        return int(value, base=2)
    elif encoding == 'd':
        return int(value, base=10)
    elif encoding == 'h':
        return int(value, base=16)
    else:
        print(f"Unsupported format {encoding} in Verilog literal {string}.")
        exit(1)


@dataclass
class RoutingTable:
    num_ids: int
    bases: list[int] = field(default_factory=list)
    masks: list[int] = field(default_factory=list)
    links: list[int] = field(default_factory=list)

    def get_owner(self, id: int) -> int:
        """Find which link to use to access the given ID."""
        owner = 0
        for base, mask, link in zip(self.bases, self.masks, self.links):
            if (id & ~mask) == base:
                owner = link
        return owner

    def get_id_range(self, link: int) -> tuple[int, int]:
        """Return the first and last IDs owned by the given link index."""
        for id in range(self.num_ids):
            if self.get_owner(id) == link:
                first = id
                break
        else:
            print(f"Couldn't find any IDs belonging to link {link}.")
            exit(1)
        
        for id in range(first, self.num_ids):
            if self.get_owner(id) != link:
                last = id - 1
                break
        else:
            last = self.num_ids - 1
        
        return first, last


def get_routing_table(config, id_name, endpoint_type):
    width = get_parameter(config, id_name + "Width", endpoint_type, 0)
    assert width > 0
    num_ids = 2 ** width

    # Check for a routing table with the form {Source, Sink}{Mask, Base, Link}.
    # If there is no routing table, look at {Source, Sink}Width and allocate
    # all bits to this component.
    if (id_name + "Link") in config:
        bases = config[id_name + "Base"]
        masks = config[id_name + "Mask"]
        links = config[id_name + "Link"]

        bases = [parse_verilog_int(base) for base in bases]
        masks = [parse_verilog_int(mask) for mask in masks]
        links = [parse_verilog_int(link) for link in links]

        return RoutingTable(num_ids, bases, masks, links)
    else:
        return RoutingTable(num_ids, [], [], [])      


def write_cpp_config(filename, config):
    cpp_config = {}

    num_hosts = int(config["hosts"])
    num_devices = int(config["devices"])

    # IDs may be modified within the TileLink network, so need separate routing
    # tables for hosts and devices.
    host_source_table = get_routing_table(config, "Source", "Host")
    host_sink_table = get_routing_table(config, "Sink", "Host")
    device_source_table = get_routing_table(config, "Source", "Device")
    device_sink_table = get_routing_table(config, "Sink", "Device")

    hosts = []
    for host in range(num_hosts):
        host_dict = {}
        
        host_dict["Protocol"] = get_parameter(config, "Protocol", "Host", "TL-C")
        host_dict["DataWidth"] = get_parameter(config, "DataWidth", "Host", 64)
        host_dict["MaxSize"] = get_parameter(config, "MaxSize", "Host", 6)
        host_dict["Fifo"] = get_parameter(config, "Fifo", "Host", 0)
        host_dict["CanDeny"] = get_parameter(config, "CanDeny", "Host", 1)

        first_id, last_id = host_source_table.get_id_range(host)
        host_dict["FirstID"] = first_id
        host_dict["LastID"] = last_id

        if num_devices > 1:
            host_dict["SinkBase"] = " ".join(str(x) for x in host_sink_table.bases)
            host_dict["SinkMask"] = " ".join(str(x) for x in host_sink_table.masks)
            host_dict["SinkTarget"] = " ".join(str(x) for x in host_sink_table.links)

        hosts.append(host_dict)
    cpp_config["hosts"] = hosts

    devices = []
    for device in range(num_devices):
        device_dict = {}

        device_dict["Protocol"] = get_parameter(config, "Protocol", "Device", "TL-C")
        device_dict["DataWidth"] = get_parameter(config, "DataWidth", "Device", 64)
        device_dict["MaxSize"] = get_parameter(config, "MaxSize", "Device", 6)
        device_dict["Fifo"] = get_parameter(config, "Fifo", "Device", 0)
        device_dict["CanDeny"] = get_parameter(config, "CanDeny", "Device", 1)

        first_id, last_id = device_sink_table.get_id_range(device)
        device_dict["FirstID"] = first_id
        device_dict["LastID"] = last_id

        # TODO: address ranges? Not currently configurable.
        if num_hosts > 1:
            device_dict["SourceBase"] = " ".join(str(x) for x in device_source_table.bases)
            device_dict["SourceMask"] = " ".join(str(x) for x in device_source_table.masks)
            device_dict["SourceTarget"] = " ".join(str(x) for x in device_source_table.links)

        devices.append(device_dict)
    cpp_config["devices"] = devices

    with open(filename, "w") as f:
        f.write("# Generated by tl_config_generator.py\n")
        f.write(f"# Configure a simulation by using e.g. tl.sim --config {filename}\n")
        yaml.dump(cpp_config, f)
    print(f"Wrote C++ config to {filename}")


def list_configs(master_config, names_only=False):
    for name, params in master_config["configs"].items():
        if name == "default":
            continue

        if names_only:
            print(name, end=" ")
        else:
            print(name, params)
    
    if names_only:
        print() # Final newline


def main():
    parser = ArgumentParser(description="Generate configuration files for Verilog and C++ parts of the simulator")
    parser.add_argument("--input", type=str, required=True, 
                        help="YAML master configuration file")
    parser.add_argument("--list", action="store_true", 
                        help="List available configurations from input file")
    parser.add_argument("--list-names", action="store_true", 
                        help="List only configuration names from input file")
    parser.add_argument("--config", type=str, 
                        help="Name of configuration from input file to use")
    parser.add_argument("--verilog", type=str, default="parameters.svh",
                        help="Filename for output Verilog configuration")
    parser.add_argument("--cpp", type=str, default="config.yaml",
                        help="Filename for output C++ configuration")

    args = parser.parse_args()

    with open(args.input) as f:
        master_config = yaml.safe_load(f)

    if args.list or args.list_names:
        list_configs(master_config, names_only=args.list_names)
        return
    
    if args.config:
        config = master_config["configs"][args.config]
    else:
        print("No configuration specified. Use --list to see available options.")
        return
    
    write_verilog_config(args.verilog, master_config["verilog_parameters"], config)
    write_cpp_config(args.cpp, config)


if __name__ == "__main__":
    main()