// Configuration Interface (Register Access)
interface config_if(input logic clk, input logic rst_n);
  logic [7:0]  addr;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic        write_en;
  logic        read_en;
  logic        ready;  //transaction complete
  
  modport master (
    output addr, wdata, write_en, read_en,
    input  rdata, ready
  );
  
  modport slave (
    input  addr, wdata, write_en, read_en,
    output rdata, ready
  );
endinterface

// Memory Interface (DMA Memory Access)
interface memory_if(input logic clk, input logic rst_n);
  logic [31:0] addr;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic        write_en;
  logic        read_en;
  logic        valid;   // Request valid
  logic        ready;   // Response ready
  
  modport master (
    output addr, wdata, write_en, read_en, valid,
    input  rdata, ready
  );
  
  modport slave (
    input  addr, wdata, write_en, read_en, valid,
    output rdata, ready
  );
endinterface


// DMA Channel Module

module dma_channel #(
  parameter CHANNEL_ID = 0
)(
  input  logic        clk,
  input  logic        rst_n,
  
  // Register Interface
  input  logic [31:0] src_addr_reg,
  input  logic [31:0] dst_addr_reg,
  input  logic [31:0] length_reg,
  input  logic        start_bit,
  output logic        busy,
  output logic        done,
  
  // Arbiter Interface
  output logic        req,
  input  logic        grant,
  
  // Memory Interface
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  input  logic [31:0] mem_rdata,
  output logic        mem_write_en,
  output logic        mem_read_en,
  output logic        mem_valid,
  input  logic        mem_ready
);

  typedef enum logic [2:0] {
    IDLE,
    READ_REQ,
    READ_WAIT,
    WRITE_REQ,
    WRITE_WAIT,
    DONE_STATE
  } state_t;
  
  state_t state, next_state;
  
  logic [31:0] current_src_addr;
  logic [31:0] current_dst_addr;
  logic [31:0] remaining_length;
  logic [31:0] read_data_buf;
  
  // State Register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end
  
  // Data Path Registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      current_src_addr <= 32'h0;
      current_dst_addr <= 32'h0;
      remaining_length <= 32'h0;
      read_data_buf    <= 32'h0;
    end else begin
      case (state)
        IDLE: begin
          if (start_bit) begin
            current_src_addr <= src_addr_reg;
            current_dst_addr <= dst_addr_reg;
            remaining_length <= length_reg;
          end
        end
        
        READ_WAIT: begin
          if (mem_ready) begin
            read_data_buf <= mem_rdata;
          end
        end
        
        WRITE_WAIT: begin
          if (mem_ready) begin
            current_src_addr <= current_src_addr + 4;
            current_dst_addr <= current_dst_addr + 4;
            remaining_length <= remaining_length - 1;
          end
        end
      endcase
    end
  end
  
  // Next State Logic
  always_comb begin
    next_state = state;
    
    case (state)
      IDLE: begin
        if (start_bit && (length_reg > 0)) begin
          next_state = READ_REQ;
        end
      end
      
      READ_REQ: begin
        if (grant) begin
          next_state = READ_WAIT;
        end
      end
      
      READ_WAIT: begin
        if (mem_ready) begin
          next_state = WRITE_REQ;
        end
      end
      
      WRITE_REQ: begin
        if (grant) begin
          next_state = WRITE_WAIT;
        end
      end
      
      WRITE_WAIT: begin
        if (mem_ready) begin
          if (remaining_length == 1) begin
            next_state = DONE_STATE;
          end else begin
            next_state = READ_REQ;
          end
        end
      end
      
      DONE_STATE: begin
        next_state = IDLE;
      end
      
      default: next_state = IDLE;
    endcase
  end
  
  // Output Logic
  always_comb begin
    req          = 1'b0;
    mem_addr     = 32'h0;
    mem_wdata    = 32'h0;
    mem_write_en = 1'b0;
    mem_read_en  = 1'b0;
    mem_valid    = 1'b0;
    busy         = 1'b0;
    done         = 1'b0;
    
    case (state)
      READ_REQ: begin
        req          = 1'b1;
        mem_addr     = current_src_addr;
        mem_read_en  = 1'b1;
        mem_valid    = grant;
        busy         = 1'b1;
      end
      
      READ_WAIT: begin
        mem_addr     = current_src_addr;
        mem_read_en  = 1'b1;
        mem_valid    = 1'b1;
        busy         = 1'b1;
      end
      
      WRITE_REQ: begin
        req          = 1'b1;
        mem_addr     = current_dst_addr;
        mem_wdata    = read_data_buf;
        mem_write_en = 1'b1;
        mem_valid    = grant;
        busy         = 1'b1;
      end
      
      WRITE_WAIT: begin
        mem_addr     = current_dst_addr;
        mem_wdata    = read_data_buf;
        mem_write_en = 1'b1;
        mem_valid    = 1'b1;
        busy         = 1'b1;
      end
      
      DONE_STATE: begin
        done = 1'b1;
      end
      
      default: begin
        busy = (state != IDLE);
      end
    endcase
  end

endmodule


// DMA Arbiter (Round-Robin)

module dma_arbiter(
  input  logic clk,
  input  logic rst_n,
  input  logic req_0,
  input  logic req_1,
  output logic grant_0,
  output logic grant_1
);

  logic last_grant;  // 0 = ch0, 1 = ch1
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_grant <= 1'b0;
      grant_0    <= 1'b0;
      grant_1    <= 1'b0;
    end else begin
      grant_0 <= 1'b0;
      grant_1 <= 1'b0;
      
      // Round-robin arbitration
      if (last_grant == 1'b0) begin
        // Last grant was ch0, prioritize ch1
        if (req_1) begin
          grant_1 <= 1'b1;
          last_grant <= 1'b1;
        end else if (req_0) begin
          grant_0 <= 1'b1;
          last_grant <= 1'b0;
        end
      end else begin
        // Last grant was ch1, prioritize ch0
        if (req_0) begin
          grant_0 <= 1'b1;
          last_grant <= 1'b0;
        end else if (req_1) begin
          grant_1 <= 1'b1;
          last_grant <= 1'b1;
        end
      end
    end
  end

endmodule


// DMA Controller Top Module

module dma_controller(
  input logic clk,
  input logic rst_n,
  config_if.slave cfg_if,
  memory_if.master mem_if
);

  // Register Map (8-bit address space)
  // Channel 0: 0x00-0x0F
  // Channel 1: 0x10-0x1F
  // 0x00/0x10: SRC_ADDR
  // 0x04/0x14: DST_ADDR
  // 0x08/0x18: LENGTH
  // 0x0C/0x1C: CONTROL (bit 0 = start, bit 1 = busy, bit 2 = done)
  
  logic [31:0] ch0_src_addr, ch0_dst_addr, ch0_length;
  logic [31:0] ch1_src_addr, ch1_dst_addr, ch1_length;
  logic        ch0_start, ch1_start;
  logic        ch0_busy, ch1_busy;
  logic        ch0_done, ch1_done;
  
  // Channel signals
  logic        ch0_req, ch1_req;
  logic        ch0_grant, ch1_grant;
  logic [31:0] ch0_mem_addr, ch1_mem_addr;
  logic [31:0] ch0_mem_wdata, ch1_mem_wdata;
  logic [31:0] ch0_mem_rdata, ch1_mem_rdata;
  logic        ch0_mem_write_en, ch1_mem_write_en;
  logic        ch0_mem_read_en, ch1_mem_read_en;
  logic        ch0_mem_valid, ch1_mem_valid;
  logic        ch0_mem_ready, ch1_mem_ready;
  
  // Register Access Logic
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ch0_src_addr <= 32'h0;
      ch0_dst_addr <= 32'h0;
      ch0_length   <= 32'h0;
      ch1_src_addr <= 32'h0;
      ch1_dst_addr <= 32'h0;
      ch1_length   <= 32'h0;
      cfg_if.rdata <= 32'h0;
      cfg_if.ready <= 1'b0;
    end else begin
      ch0_start <= 1'b0;
      ch1_start <= 1'b0;
      cfg_if.ready <= 1'b0;
      
      if (cfg_if.write_en) begin
        case (cfg_if.addr)
          8'h00: ch0_src_addr <= cfg_if.wdata;
          8'h04: ch0_dst_addr <= cfg_if.wdata;
          8'h08: ch0_length   <= cfg_if.wdata;
          8'h0C: ch0_start    <= cfg_if.wdata[0];
          8'h10: ch1_src_addr <= cfg_if.wdata;
          8'h14: ch1_dst_addr <= cfg_if.wdata;
          8'h18: ch1_length   <= cfg_if.wdata;
          8'h1C: ch1_start    <= cfg_if.wdata[0];
        endcase
        cfg_if.ready <= 1'b1;
      end
      
      if (cfg_if.read_en) begin
        case (cfg_if.addr)
          8'h00: cfg_if.rdata <= ch0_src_addr;
          8'h04: cfg_if.rdata <= ch0_dst_addr;
          8'h08: cfg_if.rdata <= ch0_length;
          8'h0C: cfg_if.rdata <= {29'h0, ch0_done, ch0_busy, 1'b0};
          8'h10: cfg_if.rdata <= ch1_src_addr;
          8'h14: cfg_if.rdata <= ch1_dst_addr;
          8'h18: cfg_if.rdata <= ch1_length;
          8'h1C: cfg_if.rdata <= {29'h0, ch1_done, ch1_busy, 1'b0};
          default: cfg_if.rdata <= 32'hDEADBEEF;
        endcase
        cfg_if.ready <= 1'b1;
      end
    end
  end
  
  // Instantiate Channels
  dma_channel #(.CHANNEL_ID(0)) ch0 (
    .clk(clk),
    .rst_n(rst_n),
    .src_addr_reg(ch0_src_addr),
    .dst_addr_reg(ch0_dst_addr),
    .length_reg(ch0_length),
    .start_bit(ch0_start),
    .busy(ch0_busy),
    .done(ch0_done),
    .req(ch0_req),
    .grant(ch0_grant),
    .mem_addr(ch0_mem_addr),
    .mem_wdata(ch0_mem_wdata),
    .mem_rdata(ch0_mem_rdata),
    .mem_write_en(ch0_mem_write_en),
    .mem_read_en(ch0_mem_read_en),
    .mem_valid(ch0_mem_valid),
    .mem_ready(ch0_mem_ready)
  );
  
  dma_channel #(.CHANNEL_ID(1)) ch1 (
    .clk(clk),
    .rst_n(rst_n),
    .src_addr_reg(ch1_src_addr),
    .dst_addr_reg(ch1_dst_addr),
    .length_reg(ch1_length),
    .start_bit(ch1_start),
    .busy(ch1_busy),
    .done(ch1_done),
    .req(ch1_req),
    .grant(ch1_grant),
    .mem_addr(ch1_mem_addr),
    .mem_wdata(ch1_mem_wdata),
    .mem_rdata(ch1_mem_rdata),
    .mem_write_en(ch1_mem_write_en),
    .mem_read_en(ch1_mem_read_en),
    .mem_valid(ch1_mem_valid),
    .mem_ready(ch1_mem_ready)
  );
  
  // Instantiate Arbiter
  dma_arbiter arb (
    .clk(clk),
    .rst_n(rst_n),
    .req_0(ch0_req),
    .req_1(ch1_req),
    .grant_0(ch0_grant),
    .grant_1(ch1_grant)
  );
  
  // Memory Interface Mux
  always_comb begin
    if (ch0_grant || (ch0_mem_valid && !ch1_grant)) begin
      mem_if.addr     = ch0_mem_addr;
      mem_if.wdata    = ch0_mem_wdata;
      mem_if.write_en = ch0_mem_write_en;
      mem_if.read_en  = ch0_mem_read_en;
      mem_if.valid    = ch0_mem_valid;
      ch0_mem_rdata   = mem_if.rdata;
      ch0_mem_ready   = mem_if.ready;
      ch1_mem_rdata   = 32'h0;
      ch1_mem_ready   = 1'b0;
    end else begin
      mem_if.addr     = ch1_mem_addr;
      mem_if.wdata    = ch1_mem_wdata;
      mem_if.write_en = ch1_mem_write_en;
      mem_if.read_en  = ch1_mem_read_en;
      mem_if.valid    = ch1_mem_valid;
      ch1_mem_rdata   = mem_if.rdata;
      ch1_mem_ready   = mem_if.ready;
      ch0_mem_rdata   = 32'h0;
      ch0_mem_ready   = 1'b0;
    end
  end

endmodule
