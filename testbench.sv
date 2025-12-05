`include "uvm_macros.svh"
import uvm_pkg::*;


// DMA Testbench Package

package dma_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  

  // Transaction Classes
  
  // Configuration Transaction
  class config_txn extends uvm_sequence_item;
    rand bit [7:0]  addr;
    rand bit [31:0] wdata;
    bit [31:0]      rdata;
    rand bit        is_write;
    
    `uvm_object_utils_begin(config_txn)
      `uvm_field_int(addr, UVM_ALL_ON)
      `uvm_field_int(wdata, UVM_ALL_ON)
      `uvm_field_int(rdata, UVM_ALL_ON)
      `uvm_field_int(is_write, UVM_ALL_ON)
    `uvm_object_utils_end
    
    function new(string name = "config_txn");
      super.new(name);
    endfunction
  endclass
  
  // Memory Transaction
  class memory_txn extends uvm_sequence_item;
    bit [31:0] addr;
    bit [31:0] wdata;
    bit [31:0] rdata;
    bit        is_write;
    
    `uvm_object_utils_begin(memory_txn)
      `uvm_field_int(addr, UVM_ALL_ON)
      `uvm_field_int(wdata, UVM_ALL_ON)
      `uvm_field_int(rdata, UVM_ALL_ON)
      `uvm_field_int(is_write, UVM_ALL_ON)
    `uvm_object_utils_end
    
    function new(string name = "memory_txn");
      super.new(name);
    endfunction
  endclass
  

  // Configuration Agent Components

  
  class config_driver extends uvm_driver #(config_txn);
    `uvm_component_utils(config_driver)
    
    virtual config_if vif;
    
    function new(string name = "config_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual config_if)::get(this, "", "config_vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found")
    endfunction
    
    task run_phase(uvm_phase phase);
      config_txn txn;
      
      vif.write_en <= 0;
      vif.read_en  <= 0;
      vif.addr     <= 0;
      vif.wdata    <= 0;
      
      forever begin
        seq_item_port.get_next_item(txn);
        
        @(posedge vif.clk);
        vif.addr <= txn.addr;
        
        if (txn.is_write) begin
          vif.wdata    <= txn.wdata;
          vif.write_en <= 1'b1;
          vif.read_en  <= 1'b0;
          `uvm_info("CFG_DRV", $sformatf("Write: addr=0x%0h, data=0x%0h", txn.addr, txn.wdata), UVM_MEDIUM)
        end else begin
          vif.write_en <= 1'b0;
          vif.read_en  <= 1'b1;
          `uvm_info("CFG_DRV", $sformatf("Read: addr=0x%0h", txn.addr), UVM_MEDIUM)
        end
        
        @(posedge vif.clk);
        wait(vif.ready);
        
        if (!txn.is_write) begin
          txn.rdata = vif.rdata;
          `uvm_info("CFG_DRV", $sformatf("Read response: data=0x%0h", txn.rdata), UVM_MEDIUM)
        end
        
        @(posedge vif.clk);
        vif.write_en <= 0;
        vif.read_en  <= 0;
        
        seq_item_port.item_done();
      end
    endtask
  endclass
  
  class config_monitor extends uvm_monitor;
    `uvm_component_utils(config_monitor)
    
    virtual config_if vif;
    uvm_analysis_port #(config_txn) ap;
    
    function new(string name = "config_monitor", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      ap = new("ap", this);
      if (!uvm_config_db#(virtual config_if)::get(this, "", "config_vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found")
    endfunction
    
    task run_phase(uvm_phase phase);
      config_txn txn;
      
      forever begin
        @(posedge vif.clk);
        if (vif.write_en || vif.read_en) begin
          txn = config_txn::type_id::create("txn");
          txn.addr = vif.addr;
          txn.is_write = vif.write_en;
          
          if (vif.write_en) begin
            txn.wdata = vif.wdata;
          end
          
          wait(vif.ready);
          @(posedge vif.clk);
          
          if (vif.read_en) begin
            txn.rdata = vif.rdata;
          end
          
          ap.write(txn);
        end
      end
    endtask
  endclass
  
  class config_sequencer extends uvm_sequencer #(config_txn);
    `uvm_component_utils(config_sequencer)
    
    function new(string name = "config_sequencer", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass
  
  class config_agent extends uvm_agent;
    `uvm_component_utils(config_agent)
    
    config_driver    drv;
    config_monitor   mon;
    config_sequencer sqr;
    
    function new(string name = "config_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = config_monitor::type_id::create("mon", this);
      if (is_active == UVM_ACTIVE) begin
        drv = config_driver::type_id::create("drv", this);
        sqr = config_sequencer::type_id::create("sqr", this);
      end
    endfunction
    
    function void connect_phase(uvm_phase phase);
      if (is_active == UVM_ACTIVE) begin
        drv.seq_item_port.connect(sqr.seq_item_export);
      end
    endfunction
  endclass
  

  // Memory Agent Components (Slave - Memory Model)

  
  class memory_driver extends uvm_driver #(memory_txn);
    `uvm_component_utils(memory_driver)
    
    virtual memory_if vif;
    bit [31:0] mem [bit[31:0]];  // Associative array as memory
    
    function new(string name = "memory_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual memory_if)::get(this, "", "memory_vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found")
    endfunction
    
    task run_phase(uvm_phase phase);
      vif.rdata <= 32'h0;
      vif.ready <= 1'b0;
      
      forever begin
        @(posedge vif.clk);
        if (vif.valid) begin
          // Add 1 cycle delay for realistic memory response
          repeat(1) @(posedge vif.clk);
          
          if (vif.write_en) begin
            mem[vif.addr] = vif.wdata;
            `uvm_info("MEM_DRV", $sformatf("Write: addr=0x%0h, data=0x%0h", vif.addr, vif.wdata), UVM_HIGH)
          end else if (vif.read_en) begin
            if (mem.exists(vif.addr)) begin
              vif.rdata <= mem[vif.addr];
              `uvm_info("MEM_DRV", $sformatf("Read: addr=0x%0h, data=0x%0h", vif.addr, mem[vif.addr]), UVM_HIGH)
            end else begin
              vif.rdata <= 32'h0;
              `uvm_info("MEM_DRV", $sformatf("Read: addr=0x%0h, data=0x%0h (uninitialized)", vif.addr, 32'h0), UVM_HIGH)
            end
          end
          
          vif.ready <= 1'b1;
          @(posedge vif.clk);
          vif.ready <= 1'b0;
        end
      end
    endtask
  endclass
  
  class memory_monitor extends uvm_monitor;
    `uvm_component_utils(memory_monitor)
    
    virtual memory_if vif;
    uvm_analysis_port #(memory_txn) ap;
    
    function new(string name = "memory_monitor", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      ap = new("ap", this);
      if (!uvm_config_db#(virtual memory_if)::get(this, "", "memory_vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found")
    endfunction
    
    task run_phase(uvm_phase phase);
      memory_txn txn;
      
      forever begin
        @(posedge vif.clk);
        if (vif.valid && vif.ready) begin
          txn = memory_txn::type_id::create("txn");
          txn.addr = vif.addr;
          txn.is_write = vif.write_en;
          
          if (vif.write_en) begin
            txn.wdata = vif.wdata;
          end else if (vif.read_en) begin
            txn.rdata = vif.rdata;
          end
          
          ap.write(txn);
        end
      end
    endtask
  endclass
  
  class memory_agent extends uvm_agent;
    `uvm_component_utils(memory_agent)
    
    memory_driver  drv;
    memory_monitor mon;
    
    function new(string name = "memory_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = memory_monitor::type_id::create("mon", this);
      if (is_active == UVM_ACTIVE) begin
        drv = memory_driver::type_id::create("drv", this);
      end
    endfunction
  endclass

  // UVM RAL Model

  
  class dma_reg extends uvm_reg;
    `uvm_object_utils(dma_reg)
    
    rand uvm_reg_field field;
    
    function new(string name = "dma_reg");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction
    
    virtual function void build();
      field = uvm_reg_field::type_id::create("field");
      field.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 1);
    endfunction
  endclass
  
  class dma_channel_reg_block extends uvm_reg_block;
    rand dma_reg src_addr;
    rand dma_reg dst_addr;
    rand dma_reg length;
    rand dma_reg control;
    
    `uvm_object_utils(dma_channel_reg_block)
    
    function new(string name = "dma_channel_reg_block");
      super.new(name, UVM_NO_COVERAGE);
    endfunction
    
    virtual function void build();
      default_map = create_map("default_map", 0, 4, UVM_LITTLE_ENDIAN);
      
      src_addr = dma_reg::type_id::create("src_addr");
      src_addr.configure(this);
      src_addr.build();
      default_map.add_reg(src_addr, 8'h00, "RW");
      
      dst_addr = dma_reg::type_id::create("dst_addr");
      dst_addr.configure(this);
      dst_addr.build();
      default_map.add_reg(dst_addr, 8'h04, "RW");
      
      length = dma_reg::type_id::create("length");
      length.configure(this);
      length.build();
      default_map.add_reg(length, 8'h08, "RW");
      
      control = dma_reg::type_id::create("control");
      control.configure(this);
      control.build();
      default_map.add_reg(control, 8'h0C, "RW");
      
      lock_model();
    endfunction
  endclass
  
  class dma_reg_model extends uvm_reg_block;
    rand dma_channel_reg_block channel0;
    rand dma_channel_reg_block channel1;
    
    `uvm_object_utils(dma_reg_model)
    
    function new(string name = "dma_reg_model");
      super.new(name, UVM_NO_COVERAGE);
    endfunction
    
    virtual function void build();
      default_map = create_map("default_map", 0, 4, UVM_LITTLE_ENDIAN);
      
      channel0 = dma_channel_reg_block::type_id::create("channel0");
      channel0.configure(this);
      channel0.build();
      default_map.add_submap(channel0.default_map, 8'h00);
      
      channel1 = dma_channel_reg_block::type_id::create("channel1");
      channel1.configure(this);
      channel1.build();
      default_map.add_submap(channel1.default_map, 8'h10);
      
      lock_model();
    endfunction
  endclass
  

  // RAL Adapter

  
  class dma_reg_adapter extends uvm_reg_adapter;
    `uvm_object_utils(dma_reg_adapter)
    
    function new(string name = "dma_reg_adapter");
      super.new(name);
    endfunction
    
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
      config_txn txn = config_txn::type_id::create("txn");
      txn.is_write = (rw.kind == UVM_WRITE);
      txn.addr = rw.addr[7:0];
      txn.wdata = rw.data;
      return txn;
    endfunction
    
    virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
      config_txn txn;
      if (!$cast(txn, bus_item)) begin
        `uvm_fatal("CAST", "Failed to cast bus_item to config_txn")
      end
      rw.kind = txn.is_write ? UVM_WRITE : UVM_READ;
      rw.addr = txn.addr;
      rw.data = txn.is_write ? txn.wdata : txn.rdata;
      rw.status = UVM_IS_OK;
    endfunction
  endclass
  

  // Scoreboard

  
  class dma_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(dma_scoreboard)
    
    uvm_analysis_imp #(memory_txn, dma_scoreboard) mem_analysis_imp;
    
    bit [31:0] golden_mem [bit[31:0]];  // Golden memory model
    bit [31:0] read_tracker [bit[31:0]]; // Track what addresses were read (sources)
    int error_count;
    int check_count;
    int read_count;
    int write_count;
    
    function new(string name = "dma_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      error_count = 0;
      check_count = 0;
      read_count = 0;
      write_count = 0;
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mem_analysis_imp = new("mem_analysis_imp", this);
    endfunction
    
    virtual function void write(memory_txn txn);
      if (txn.is_write) begin
        write_count++;
        
        // Check if we have a corresponding read (DMA source)
        if (read_tracker.exists(txn.addr)) begin
          // This is a known destination address that maps to a source
          bit [31:0] expected_data = read_tracker[txn.addr];
          check_count++;
          
          if (txn.wdata === expected_data) begin
            `uvm_info("SCB", $sformatf("PASS: addr=0x%0h, data=0x%0h matches expected", txn.addr, txn.wdata), UVM_LOW)
          end else begin
            error_count++;
            `uvm_error("SCB", $sformatf("FAIL: addr=0x%0h, data=0x%0h, expected=0x%0h", txn.addr, txn.wdata, expected_data))
          end
        end else begin
          // Store write for reference (could be initial memory setup)
          golden_mem[txn.addr] = txn.wdata;
          `uvm_info("SCB", $sformatf("Stored write: addr=0x%0h, data=0x%0h", txn.addr, txn.wdata), UVM_HIGH)
        end
      end else begin
        // Read transaction - track for future write comparison
        read_count++;
        read_tracker[txn.addr] = txn.rdata;
        golden_mem[txn.addr] = txn.rdata;
        `uvm_info("SCB", $sformatf("Tracked read: addr=0x%0h, data=0x%0h", txn.addr, txn.rdata), UVM_HIGH)
      end
    endfunction
    
    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("SCB", "========================================", UVM_LOW)
      `uvm_info("SCB", "      SCOREBOARD FINAL REPORT", UVM_LOW)
      `uvm_info("SCB", "========================================", UVM_LOW)
      `uvm_info("SCB", $sformatf("Total Reads:  %0d", read_count), UVM_LOW)
      `uvm_info("SCB", $sformatf("Total Writes: %0d", write_count), UVM_LOW)
      `uvm_info("SCB", $sformatf("Total Checks: %0d", check_count), UVM_LOW)
      `uvm_info("SCB", $sformatf("Total Errors: %0d", error_count), UVM_LOW)
      `uvm_info("SCB", "========================================", UVM_LOW)
      
      if (error_count == 0 && check_count > 0) begin
        `uvm_info("SCB", "*** ALL CHECKS PASSED ***", UVM_LOW)
      end else if (error_count > 0) begin
        `uvm_error("SCB", "*** CHECKS FAILED ***")
      end else if (check_count == 0) begin
        `uvm_warning("SCB", "*** NO CHECKS PERFORMED ***")
      end
    endfunction
  endclass
  

  // Environment

  
  class dma_env extends uvm_env;
    `uvm_component_utils(dma_env)
    
    config_agent cfg_agent;
    memory_agent mem_agent;
    dma_reg_model reg_model;
    dma_reg_adapter reg_adapter;
    dma_scoreboard scb;
    
    function new(string name = "dma_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      
      cfg_agent = config_agent::type_id::create("cfg_agent", this);
      cfg_agent.is_active = UVM_ACTIVE;
      
      mem_agent = memory_agent::type_id::create("mem_agent", this);
      mem_agent.is_active = UVM_ACTIVE;
      
      reg_model = dma_reg_model::type_id::create("reg_model");
      reg_model.build();
      
      reg_adapter = dma_reg_adapter::type_id::create("reg_adapter");
      
      scb = dma_scoreboard::type_id::create("scb", this);
    endfunction
    
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      
      // Connect RAL to config agent
      reg_model.default_map.set_sequencer(cfg_agent.sqr, reg_adapter);
      reg_model.default_map.set_auto_predict(1);
      
      // Connect memory monitor to scoreboard
      mem_agent.mon.ap.connect(scb.mem_analysis_imp);
    endfunction
  endclass

  // Base Test

  
  class base_test extends uvm_test;
    `uvm_component_utils(base_test)
    
    dma_env env;
    
    function new(string name = "base_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = dma_env::type_id::create("env", this);
    endfunction
    
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      uvm_top.print_topology();
    endfunction
    
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      `uvm_info("TEST", "Starting base test", UVM_LOW)
      #1000ns;
      `uvm_info("TEST", "Ending base test", UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass
  

  // Simple Transfer Test (Original - Unchanged)

  
  class simple_transfer_test extends base_test;
    `uvm_component_utils(simple_transfer_test)
    
    function new(string name = "simple_transfer_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    task run_phase(uvm_phase phase);
      uvm_status_e status;
      uvm_reg_data_t rdata;
      
      phase.raise_objection(this);
      
      `uvm_info("TEST", "=== Starting Simple Transfer Test ===", UVM_LOW)
      
      // Wait for reset
      #100ns;
      
      // Initialize source memory with test pattern
      `uvm_info("TEST", "Initializing source memory...", UVM_LOW)
      for (int i = 0; i < 4; i++) begin
        env.mem_agent.drv.mem[32'h1000 + (i*4)] = 32'hA0 + i;
      end
      
      // Configure Channel 0 via RAL
      `uvm_info("TEST", "Configuring Channel 0 via RAL...", UVM_LOW)
      env.reg_model.channel0.src_addr.write(status, 32'h1000);
      env.reg_model.channel0.dst_addr.write(status, 32'h2000);
      env.reg_model.channel0.length.write(status, 32'h4);
      
      // Start transfer
      `uvm_info("TEST", "Starting DMA transfer...", UVM_LOW)
      env.reg_model.channel0.control.write(status, 32'h1);  // Start bit
      
      // Wait for transfer to complete
      #2000ns;
      
      // Check status
      env.reg_model.channel0.control.read(status, rdata);
      `uvm_info("TEST", $sformatf("Final status: 0x%0h", rdata), UVM_LOW)
      
      `uvm_info("TEST", "=== Simple Transfer Test Complete ===", UVM_LOW)
      
      phase.drop_objection(this);
    endtask
  endclass
  

  // Dual Channel Test - Tests both channels and arbitration

  
  class dual_channel_test extends base_test;
    `uvm_component_utils(dual_channel_test)
    
    function new(string name = "dual_channel_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    task run_phase(uvm_phase phase);
      uvm_status_e status;
      uvm_reg_data_t rdata0, rdata1;
      
      phase.raise_objection(this);
      
      `uvm_info("TEST", "=== Starting Dual Channel Test ===", UVM_LOW)
      
      #100ns;
      
      // Initialize source memory for both channels
      `uvm_info("TEST", "Initializing source memory for both channels...", UVM_LOW)
      for (int i = 0; i < 4; i++) begin
        env.mem_agent.drv.mem[32'h1000 + (i*4)] = 32'hA0 + i;  // Channel 0 source
        env.mem_agent.drv.mem[32'h3000 + (i*4)] = 32'hB0 + i;  // Channel 1 source
      end
      
      // Configure Channel 0
      `uvm_info("TEST", "Configuring Channel 0...", UVM_LOW)
      env.reg_model.channel0.src_addr.write(status, 32'h1000);
      env.reg_model.channel0.dst_addr.write(status, 32'h2000);
      env.reg_model.channel0.length.write(status, 32'h4);
      
      // Configure Channel 1
      `uvm_info("TEST", "Configuring Channel 1...", UVM_LOW)
      env.reg_model.channel1.src_addr.write(status, 32'h3000);
      env.reg_model.channel1.dst_addr.write(status, 32'h4000);
      env.reg_model.channel1.length.write(status, 32'h4);
      
      // Start both channels simultaneously
      `uvm_info("TEST", "Starting both DMA channels simultaneously...", UVM_LOW)
      env.reg_model.channel0.control.write(status, 32'h1);
      env.reg_model.channel1.control.write(status, 32'h1);
      
      // Wait for both transfers to complete
      #4000ns;
      
      // Check status of both channels
      env.reg_model.channel0.control.read(status, rdata0);
      env.reg_model.channel1.control.read(status, rdata1);
      `uvm_info("TEST", $sformatf("Channel 0 status: 0x%0h, Channel 1 status: 0x%0h", rdata0, rdata1), UVM_LOW)
      
      `uvm_info("TEST", "=== Dual Channel Test Complete ===", UVM_LOW)
      
      phase.drop_objection(this);
    endtask
  endclass
  

  // Stress Test - Multiple back-to-back transfers

 
  class stress_test extends base_test;
    `uvm_component_utils(stress_test)
    
    function new(string name = "stress_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    task run_phase(uvm_phase phase);
      uvm_status_e status;
      uvm_reg_data_t rdata;
      
      phase.raise_objection(this);
      
      `uvm_info("TEST", "=== Starting Stress Test ===", UVM_LOW)
      
      #100ns;
      
      // Run multiple transfers back-to-back
      for (int xfer = 0; xfer < 3; xfer++) begin
        `uvm_info("TEST", $sformatf("--- Transfer #%0d ---", xfer), UVM_LOW)
        
        // Initialize source memory with unique pattern
        for (int i = 0; i < 8; i++) begin
          env.mem_agent.drv.mem[32'h5000 + (i*4)] = 32'h100 * (xfer + 1) + i;
        end
        
        // Configure and start transfer
        env.reg_model.channel0.src_addr.write(status, 32'h5000);
        env.reg_model.channel0.dst_addr.write(status, 32'h6000 + (xfer * 32));
        env.reg_model.channel0.length.write(status, 32'h8);
        env.reg_model.channel0.control.write(status, 32'h1);
        
        // Wait for completion
        #3000ns;
        
        env.reg_model.channel0.control.read(status, rdata);
        `uvm_info("TEST", $sformatf("Transfer #%0d status: 0x%0h", xfer, rdata), UVM_LOW)
      end
      
      `uvm_info("TEST", "=== Stress Test Complete ===", UVM_LOW)
      
      phase.drop_objection(this);
    endtask
  endclass
  

  // Random Test - Randomized transfers

 
  class random_test extends base_test;
    `uvm_component_utils(random_test)
    
    rand bit [31:0] src_base;
    rand bit [31:0] dst_base;
    rand bit [7:0]  length;
    
    constraint valid_addresses {
      src_base[1:0] == 2'b00;  
      dst_base[1:0] == 2'b00;
      src_base inside {[32'h1000:32'h8000]};
      dst_base inside {[32'h1000:32'h8000]};
      src_base != dst_base;
    }
    
    constraint reasonable_length {
      length inside {[1:16]};
    }
    
    function new(string name = "random_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    task run_phase(uvm_phase phase);
      uvm_status_e status;
      
      phase.raise_objection(this);
      
      `uvm_info("TEST", "=== Starting Random Test ===", UVM_LOW)
      
      #100ns;
      
      // Run multiple randomized transfers
      for (int iter = 0; iter < 5; iter++) begin
        // Randomize parameters
        if (!this.randomize()) begin
          `uvm_error("TEST", "Randomization failed")
        end
        
        `uvm_info("TEST", $sformatf("Iteration %0d: src=0x%0h, dst=0x%0h, len=%0d", 
                  iter, src_base, dst_base, length), UVM_LOW)
        
        // Initialize source memory
        for (int i = 0; i < length; i++) begin
          env.mem_agent.drv.mem[src_base + (i*4)] = $urandom();
        end
        
        // Configure and start
        env.reg_model.channel0.src_addr.write(status, src_base);
        env.reg_model.channel0.dst_addr.write(status, dst_base);
        env.reg_model.channel0.length.write(status, length);
        env.reg_model.channel0.control.write(status, 32'h1);
        
        // Wait for completion
        #(length * 100ns + 1000ns);
      end
      
      `uvm_info("TEST", "=== Random Test Complete ===", UVM_LOW)
      
      phase.drop_objection(this);
    endtask
  endclass
  

  // Error Test - Test error conditions

  
  class error_test extends base_test;
    `uvm_component_utils(error_test)
    
    function new(string name = "error_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    task run_phase(uvm_phase phase);
      uvm_status_e status;
      
      phase.raise_objection(this);
      
      `uvm_info("TEST", "=== Starting Error Test ===", UVM_LOW)
      
      #100ns;
      
      // Test 1: Zero length transfer (should not start)
      `uvm_info("TEST", "Test 1: Zero length transfer", UVM_LOW)
      env.reg_model.channel0.src_addr.write(status, 32'h1000);
      env.reg_model.channel0.dst_addr.write(status, 32'h2000);
      env.reg_model.channel0.length.write(status, 32'h0);
      env.reg_model.channel0.control.write(status, 32'h1);
      #500ns;
      `uvm_info("TEST", "Zero length test complete (DMA should not start)", UVM_LOW)
      
      // Test 2: Unaligned addresses (system still works, testing robustness)
      `uvm_info("TEST", "Test 2: Testing with valid aligned addresses", UVM_LOW)
      for (int i = 0; i < 4; i++) begin
        env.mem_agent.drv.mem[32'h1004 + (i*4)] = 32'hC0 + i;
      end
      env.reg_model.channel0.src_addr.write(status, 32'h1004);
      env.reg_model.channel0.dst_addr.write(status, 32'h2004);
      env.reg_model.channel0.length.write(status, 32'h4);
      env.reg_model.channel0.control.write(status, 32'h1);
      #2000ns;
      
      `uvm_info("TEST", "=== Error Test Complete ===", UVM_LOW)
      
      phase.drop_objection(this);
    endtask
  endclass
  

  // Coverage Test - Exercise different scenarios for coverage

 
  class coverage_test extends base_test;
    `uvm_component_utils(coverage_test)
    
    function new(string name = "coverage_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    
    task run_phase(uvm_phase phase);
      uvm_status_e status;
      
      phase.raise_objection(this);
      
      `uvm_info("TEST", "=== Starting Coverage Test ===", UVM_LOW)
      
      #100ns;
      
      // Scenario 1: Minimum length (1 word)
      `uvm_info("TEST", "Scenario 1: Minimum length transfer", UVM_LOW)
      env.mem_agent.drv.mem[32'h7000] = 32'hDEADBEEF;
      env.reg_model.channel0.src_addr.write(status, 32'h7000);
      env.reg_model.channel0.dst_addr.write(status, 32'h8000);
      env.reg_model.channel0.length.write(status, 32'h1);
      env.reg_model.channel0.control.write(status, 32'h1);
      #1000ns;
      
      // Scenario 2: Maximum reasonable length
      `uvm_info("TEST", "Scenario 2: Larger transfer (16 words)", UVM_LOW)
      for (int i = 0; i < 16; i++) begin
        env.mem_agent.drv.mem[32'h7100 + (i*4)] = 32'hF000 + i;
      end
      env.reg_model.channel0.src_addr.write(status, 32'h7100);
      env.reg_model.channel0.dst_addr.write(status, 32'h8100);
      env.reg_model.channel0.length.write(status, 32'h10);
      env.reg_model.channel0.control.write(status, 32'h1);
      #5000ns;
      
      // Scenario 3: Use channel 1
      `uvm_info("TEST", "Scenario 3: Channel 1 usage", UVM_LOW)
      for (int i = 0; i < 4; i++) begin
        env.mem_agent.drv.mem[32'h7200 + (i*4)] = 32'hCAFE0000 + i;
      end
      env.reg_model.channel1.src_addr.write(status, 32'h7200);
      env.reg_model.channel1.dst_addr.write(status, 32'h8200);
      env.reg_model.channel1.length.write(status, 32'h4);
      env.reg_model.channel1.control.write(status, 32'h1);
      #2000ns;
      
      `uvm_info("TEST", "=== Coverage Test Complete ===", UVM_LOW)
      
      phase.drop_objection(this);
    endtask
  endclass
  
endpackage


// Top Module

module top;
  import uvm_pkg::*;
  import dma_tb_pkg::*;
 
  // Clock and Reset
  logic clk;
  logic rst_n;
  
  // Interfaces
  config_if cfg_if(clk, rst_n);
  memory_if mem_if(clk, rst_n);
  
  // DUT
  dma_controller dut (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_if(cfg_if),
    .mem_if(mem_if)
  );
  
  // Clock Generation
  initial begin
    clk = 0;
    forever #5ns clk = ~clk;
  end
  
  // Reset Generation
  initial begin
    rst_n = 0;
    #50ns;
    rst_n = 1;
  end
  
  // UVM Configuration
  initial begin
    uvm_config_db#(virtual config_if)::set(null, "uvm_test_top.env.cfg_agent*", "config_vif", cfg_if);
    uvm_config_db#(virtual memory_if)::set(null, "uvm_test_top.env.mem_agent*", "memory_vif", mem_if);
    
    // Enable waveform dumping for EPWave
    $dumpfile("dump.vcd");
    $dumpvars(0, top);
    
    // Run test
    //run_test("simple_transfer_test");
    run_test("dual_channel_test");
    //run_test("stress_test");
    //run_test("random_test");
    //run_test("error_test");
    //run_test("coverage_test");
  end
  
  // Signal Monitoring for Terminal Output
  initial begin
    $display("\n========================================");
    $display("     DMA Controller Simulation Start");
    $display("========================================\n");
    
    wait(rst_n);
    @(posedge clk);
    
    forever begin
      @(posedge clk);
      
      // Monitor Configuration Interface
      if (cfg_if.write_en || cfg_if.read_en) begin
        if (cfg_if.write_en)
          $display("[%0t] CONFIG WRITE: addr=0x%02h, wdata=0x%08h", $time, cfg_if.addr, cfg_if.wdata);
        else
          $display("[%0t] CONFIG READ:  addr=0x%02h, rdata=0x%08h", $time, cfg_if.addr, cfg_if.rdata);
      end
      
      // Monitor Memory Interface
      if (mem_if.valid && mem_if.ready) begin
        if (mem_if.write_en)
          $display("[%0t] MEM WRITE:    addr=0x%08h, data=0x%08h", $time, mem_if.addr, mem_if.wdata);
        else if (mem_if.read_en)
          $display("[%0t] MEM READ:     addr=0x%08h, data=0x%08h", $time, mem_if.addr, mem_if.rdata);
      end
      
      // Monitor DMA Channel States
      if (dut.ch0_busy || dut.ch0_done)
        $display("[%0t] CHANNEL 0:    busy=%0b, done=%0b, state=%0s", 
                 $time, dut.ch0_busy, dut.ch0_done, dut.ch0.state.name());
      
      if (dut.ch1_busy || dut.ch1_done)
        $display("[%0t] CHANNEL 1:    busy=%0b, done=%0b, state=%0s", 
                 $time, dut.ch1_busy, dut.ch1_done, dut.ch1.state.name());
    end
  end
  
  // Timeout watchdog
  initial begin
    #50us;
    $display("\n========================================");
    $display("     TIMEOUT - Simulation End");
    $display("========================================\n");
    `uvm_fatal("TIMEOUT", "Test timed out!")
  end
  
  // Final summary
  final begin
    $display("\n========================================");
    $display("     DMA Controller Simulation End");
    $display("========================================\n");
  end
  
endmodule
