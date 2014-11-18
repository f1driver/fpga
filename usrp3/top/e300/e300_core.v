//
// Copyright 2013-2014 Ettus Research LLC
//

module e300_core
#(
  parameter NUM_CE = 3
)
(
  // bus interfaces
  input             bus_clk,
  input             bus_rst,

  //axi fifo out from data mover
  input [63:0]      h2s_tdata,
  input             h2s_tlast,
  input             h2s_tvalid,
  output            h2s_tready,

  //axi fifo in to data mover
  output [63:0]     s2h_tdata,
  output            s2h_tlast,
  output            s2h_tvalid,
  input             s2h_tready,

  // radio interfaces
  input             radio_clk,
  input             radio_rst,
  input [31:0]      rx_data0,
  output [31:0]     tx_data0,
  input [31:0]      rx_data1,
  output [31:0]     tx_data1,

  // gpio controls
  output [31:0]     ctrl_out0,
  output [31:0]     ctrl_out1,
  output [2:0]      leds0,
  output [2:0]      leds1,

  // settings bus to control global registers
  input [31:0]      set_data,
  input [31:0]      set_addr,
  input             set_stb,
  output reg [31:0] rb_data,

  // settings bus to crossbar registers
  input [31:0]      xbar_set_data,
  input [31:0]      xbar_set_addr,
  input             xbar_set_stb,
  output [31:0]     xbar_rb_data,
  input [31:0]      xbar_rb_addr,
  input             xbar_rb_stb,

  // pps signals -- muxing happens toplevel
  output [1:0]      pps_select,
  input             pps,

  // mimo
  output            mimo,

  // codec async reset
  output            codec_arst,

  // bandselects
  output [2:0]      tx_bandsel,
  output [5:0]      rx_bandsel_a,
  output [3:0]      rx_bandsel_b,
  output [3:0]      rx_bandsel_c,

  // front panel (internal) gpio
  inout [5:0]       fp_gpio,

  // signals for ad9361 pll locks
  input [1:0]       lock_signals,

  output [31:0]     debug
);

  reg [1:0] lock_state;
  reg [1:0] lock_state_r;

  always @(posedge bus_clk)
    if (bus_rst)
      {lock_state_r, lock_state} <= 4'h0;
    else
      {lock_state_r, lock_state} <= {lock_state, lock_signals};


  // Global register offsets
  localparam SR_CORE_READBACK = 11'd0;
  localparam SR_CORE_MISC     = 11'd4;
  localparam SR_CORE_TEST     = 11'd28;
  localparam SR_CORE_XB_LOCAL = 11'd32;

  localparam RB32_CORE_MISC     = 5'd1;
  localparam RB32_CORE_COMPAT   = 5'd2;
  localparam RB32_CORE_GITHASH  = 5'd3;
  localparam RB32_CORE_PLL      = 5'd4;
  localparam RB32_CORE_NUMCE    = 5'd8;
  localparam RB32_CORE_TEST     = 5'd24;

  wire [4:0]  rb_addr;
  wire [31:0] rb_test;
  wire [31:0] rb_data_xb;
  wire [7:0] xb_local_addr;

  wire [31:0] misc_out;


  setting_reg
  #( .my_addr(SR_CORE_READBACK),
     .awidth(11), .width(5),
     .at_reset(2'h0)
  ) sr_readback_addr
  (
    .clk(bus_clk), .rst(bus_rst),
    .strobe(set_stb), .addr(set_addr),
    .in(set_data), .out(rb_addr),
    .changed()
  );

  setting_reg
  #( .my_addr(SR_CORE_TEST),
     .awidth(11), .width(32),
     .at_reset(32'h0)
  ) sr_test
  (
    .clk(bus_clk), .rst(bus_rst),
    .strobe(set_stb), .addr(set_addr),
    .in(set_data), .out(rb_test),
    .changed()
  );

  // the at_reset value 2'b10 selects
  // the internal pps signal as default
  setting_reg
  #(
    .my_addr(SR_CORE_MISC),
    .awidth(11), .width(32),
    .at_reset({30'h0, 2'b10})
  ) sr_misc
  (
    .clk(bus_clk), .rst(bus_rst),
    .strobe(set_stb), .addr(set_addr),
    .in(set_data), .out(misc_out),
    .changed()
  );

  assign pps_select   = misc_out[1:0];
  assign mimo         = misc_out[2];
  assign codec_arst   = misc_out[3];
  assign tx_bandsel   = misc_out[6:4];
  assign rx_bandsel_a = misc_out[12:7];
  assign rx_bandsel_b = misc_out[16:13];
  assign rx_bandsel_c = misc_out[20:17];

  setting_reg
  #(
    .my_addr(SR_CORE_XB_LOCAL),
    .awidth(11), .width(8),
    .at_reset(11'd40)
  ) sr_xb_local
  (
    .clk(bus_clk), .rst(bus_rst),
    .strobe(set_stb), .addr(set_addr),
    .in(set_data), .out(xb_local_addr),
    .changed()
  );

  always @(*)
    case(rb_addr)
      RB32_CORE_TEST    : rb_data <= rb_test;
      RB32_CORE_MISC    : rb_data <= {30'd0, pps_select};
      RB32_CORE_COMPAT  : rb_data <= {8'hAC, 8'h0, 8'h4, 8'h0};
      RB32_CORE_GITHASH : rb_data <= 32'h`GIT_HASH;
      RB32_CORE_PLL     : rb_data <= {30'h0, lock_state_r};
      RB32_CORE_NUMCE   : rb_data <= {28'h0, NUM_CE};
      default           : rb_data <= 64'hdeadbeef;
    endcase


  ////////////////////////////////////////////////////////////////////
  // routing logic, aka crossbar
  ////////////////////////////////////////////////////////////////////

  wire [63:0]          ro_tdata [1:0];
  wire                 ro_tlast [1:0];
  wire                 ro_tvalid [1:0];
  wire                 ro_tready [1:0];

  wire [63:0]          ri_tdata [1:0];
  wire                 ri_tlast [1:0];
  wire                 ri_tvalid [1:0];
  wire                 ri_tready [1:0];

  wire [NUM_CE*64-1:0] ce_flat_o_tdata;
  wire [63:0]          ce_o_tdata[NUM_CE-1:0];
  wire [NUM_CE-1:0]    ce_o_tlast;
  wire [NUM_CE-1:0]    ce_o_tvalid;
  wire [NUM_CE-1:0]    ce_o_tready;

  wire [NUM_CE*64-1:0] ce_flat_i_tdata;
  wire [63:0]          ce_i_tdata[NUM_CE-1:0];
  wire [NUM_CE-1:0]    ce_i_tlast;
  wire [NUM_CE-1:0]    ce_i_tvalid;
  wire [NUM_CE-1:0]    ce_i_tready;

  // Flattern CE tdata arrays
  genvar k;
  generate
  for (k = 0; k < NUM_CE; k = k + 1) begin
    assign ce_o_tdata[k] = ce_flat_o_tdata[k*64+63:k*64];
    assign ce_flat_i_tdata[k*64+63:k*64] = ce_i_tdata[k];
  end
  endgenerate

  localparam CROSSBAR_IN = 3 + NUM_CE;
  localparam CROSSBAR_OUT = 3 + NUM_CE;

  `define LOG2(N) (\
                 N < 2 ? 0 : \
                 N < 4 ? 1 : \
                 N < 8 ? 2 : \
                 N < 16 ? 3 : \
                 N < 32 ? 4 : \
                 N < 64 ? 5 : \
                 N < 128 ? 6 : \
                 N < 256 ? 7 : \
                 N < 512 ? 8 : \
                 N < 1024 ? 9 : \
                 10)

  // axi crossbar ports
  // 0 - Host
  // 1 - Radio0
  // 2 - Radio1
  // 3 - CE0
  // 4 - CE1
  // 5 - CE2

  axi_crossbar
  #(
    .BASE(0), // TODO: Set to 0 as logic for other values has not been tested
    .FIFO_WIDTH(64),
    .DST_WIDTH(16),
    .NUM_INPUTS(CROSSBAR_IN),
    .NUM_OUTPUTS(CROSSBAR_OUT)
  ) axi_crossbar
  (
    .clk(bus_clk),
    .reset(bus_rst),
    .clear(1'b0),
    .local_addr(xb_local_addr),

    // settings bus for config
    .set_stb(xbar_set_stb),
    .set_addr({7'd0, xbar_set_addr[10:2]}), // Settings bus is word aligned, so drop lower two LSBs.
                                            // Also, upper bits are masked to 0 as BASE address is set to 0.
    .set_data(xbar_set_data),
    .rb_rd_stb(xbar_rb_stb),
    .rb_addr(xbar_rb_addr[`LOG2(CROSSBAR_IN)+`LOG2(CROSSBAR_OUT)-1+2:2]), // Also word aligned
    .rb_data(xbar_rb_data),

    // inputs, real men flatten busses
    .i_tdata({ce_flat_i_tdata, ri_tdata[1], ri_tdata[0], h2s_tdata}),
    .i_tlast({ce_i_tlast, ri_tlast[1], ri_tlast[0], h2s_tlast}),
    .i_tvalid({ce_i_tvalid, ri_tvalid[1], ri_tvalid[0], h2s_tvalid}),
    .i_tready({ce_i_tready, ri_tready[1], ri_tready[0], h2s_tready}),

    // outputs, real men flatten busses
    .o_tdata({ce_flat_o_tdata, ro_tdata[1], ro_tdata[0], s2h_tdata}),
    .o_tlast({ce_o_tlast, ro_tlast[1], ro_tlast[0], s2h_tlast}),
    .o_tvalid({ce_o_tvalid, ro_tvalid[1], ro_tvalid[0], s2h_tvalid}),
    .o_tready({ce_o_tready, ro_tready[1], ro_tready[0], s2h_tready}),
    .pkt_present({ce_i_tvalid, ri_tvalid[1], ri_tvalid[0], h2s_tvalid})
  );


  /*
  noc_block_fir_filter #(
    .NOC_ID(64'hF112_0000_0000_0000),
    .STR_SINK_FIFOSIZE(11))
  inst_noc_block_fir_filter (
    .bus_clk(bus_clk), .bus_rst(bus_rst),
    .ce_clk(bus_clk), .ce_rst(bus_rst),
    .i_tdata(ce_o_tdata[0]), .i_tlast(ce_o_tlast[0]), .i_tvalid(ce_o_tvalid[0]), .i_tready(ce_o_tready[0]),
    .o_tdata(ce_i_tdata[0]), .o_tlast(ce_i_tlast[0]), .o_tvalid(ce_i_tvalid[0]), .o_tready(ce_i_tready[0]),
    .debug());
    */

  noc_block_axi_fifo_loopback #(
    .NOC_ID(64'hF1F0_0000_0000_0000),
    .STR_SINK_FIFOSIZE(11))
  inst_noc_block_axi_fifo_loopback (
    .bus_clk(bus_clk), .bus_rst(bus_rst),
    .ce_clk(bus_clk), .ce_rst(bus_rst),
    .i_tdata(ce_o_tdata[0]), .i_tlast(ce_o_tlast[0]), .i_tvalid(ce_o_tvalid[0]), .i_tready(ce_o_tready[0]),
    .o_tdata(ce_i_tdata[0]), .o_tlast(ce_i_tlast[0]), .o_tvalid(ce_i_tvalid[0]), .o_tready(ce_i_tready[0]),
    .debug());

  noc_block_null_source_sink #(
    .NOC_ID(64'h0000_0000_0000_0000),
    .STR_SINK_FIFOSIZE(11))
  inst_noc_block_null_source_sink (
    .bus_clk(bus_clk), .bus_rst(bus_rst),
    .ce_clk(bus_clk), .ce_rst(bus_rst),
    .i_tdata(ce_o_tdata[1]), .i_tlast(ce_o_tlast[1]), .i_tvalid(ce_o_tvalid[1]), .i_tready(ce_o_tready[1]),
    .o_tdata(ce_i_tdata[1]), .o_tlast(ce_i_tlast[1]), .o_tvalid(ce_i_tvalid[1]), .o_tready(ce_i_tready[1]),
    .debug());

  noc_block_fft #(
    .NOC_ID(64'hFF70_0000_0000_0000),
    .STR_SINK_FIFOSIZE(11))
  inst_noc_block_fft (
    .bus_clk(bus_clk), .bus_rst(bus_rst),
    .ce_clk(bus_clk), .ce_rst(bus_rst),
    .i_tdata(ce_o_tdata[2]), .i_tlast(ce_o_tlast[2]), .i_tvalid(ce_o_tvalid[2]), .i_tready(ce_o_tready[2]),
    .o_tdata(ce_i_tdata[2]), .o_tlast(ce_i_tlast[2]), .o_tvalid(ce_i_tvalid[2]), .o_tready(ce_i_tready[2]),
    .debug());

  ////////////////////////////////////////////////////////////////////
  // radio instantiation
  ////////////////////////////////////////////////////////////////////
  wire [63:0] tx_tdata_bo [1:0], tx_tdata_bi [1:0];
  wire tx_tlast_bo[1:0], tx_tvalid_bo [1:0], tx_tready_bo [1:0];
  wire tx_tlast_bi[1:0], tx_tvalid_bi [1:0], tx_tready_bi [1:0];

  axi_fifo #(.WIDTH(65), .SIZE(11)) axi_fifo_tx_packet_buff0
  (
    .clk(bus_clk), .reset(bus_rst), .clear(1'b0),
    .i_tdata({tx_tlast_bo[0], tx_tdata_bo[0]}), .i_tvalid(tx_tvalid_bo[0]), .i_tready(tx_tready_bo[0]),
    .o_tdata({tx_tlast_bi[0], tx_tdata_bi[0]}), .o_tvalid(tx_tvalid_bi[0]), .o_tready(tx_tready_bi[0]),
    .occupied()
  );

  radio #(.RADIO_NUM(0), .DATA_FIFO_SIZE(13), .MSG_FIFO_SIZE(9)) radio0
  (
    //radio domain stuff
    .radio_clk(radio_clk), .radio_rst(radio_rst),

    //not connected
    .rx(rx_data0), .tx(tx_data0),
    .db_gpio(ctrl_out0),
    .fp_gpio(fp_gpio),
    .sen(), .sclk(), .mosi(), .miso(),
    .misc_outs(), .leds(leds0),

    //bus clock domain and fifos
    .bus_clk(bus_clk), .bus_rst(bus_rst),
    .in_tdata(ro_tdata[0]), .in_tlast(ro_tlast[0]), .in_tvalid(ro_tvalid[0]), .in_tready(ro_tready[0]),
    .out_tdata(ri_tdata[0]), .out_tlast(ri_tlast[0]), .out_tvalid(ri_tvalid[0]), .out_tready(ri_tready[0]),

    //tx buffering -- used for insertion of axi_fifo_tx_packet_buff
    .tx_tdata_bo(tx_tdata_bo[0]), .tx_tlast_bo(tx_tlast_bo[0]), .tx_tvalid_bo(tx_tvalid_bo[0]), .tx_tready_bo(tx_tready_bo[0]),
    .tx_tdata_bi(tx_tdata_bi[0]), .tx_tlast_bi(tx_tlast_bi[0]), .tx_tvalid_bi(tx_tvalid_bi[0]), .tx_tready_bi(tx_tready_bi[0]),

    .pps(pps), .sync_dacs(),
    .debug()
  );

  axi_fifo #(.WIDTH(65), .SIZE(11)) axi_fifo_tx_packet_buff1
  (
    .clk(bus_clk), .reset(bus_rst), .clear(1'b0),
    .i_tdata({tx_tlast_bo[1], tx_tdata_bo[1]}), .i_tvalid(tx_tvalid_bo[1]), .i_tready(tx_tready_bo[1]),
    .o_tdata({tx_tlast_bi[1], tx_tdata_bi[1]}), .o_tvalid(tx_tvalid_bi[1]), .o_tready(tx_tready_bi[1]),
    .occupied()
  );

  radio #(.RADIO_NUM(1), .DATA_FIFO_SIZE(13), .MSG_FIFO_SIZE(9)) radio1
  (
    //radio domain stuff
    .radio_clk(radio_clk), .radio_rst(radio_rst),

    //not connected
    .rx(rx_data1), .tx(tx_data1),
    .db_gpio(ctrl_out1),
    .fp_gpio(),
    .sen(), .sclk(), .mosi(), .miso(),
    .misc_outs(), .leds(leds1),

    //bus clock domain and fifos
    .bus_clk(bus_clk), .bus_rst(bus_rst),
    .in_tdata(ro_tdata[1]), .in_tlast(ro_tlast[1]), .in_tvalid(ro_tvalid[1]), .in_tready(ro_tready[1]),
    .out_tdata(ri_tdata[1]), .out_tlast(ri_tlast[1]), .out_tvalid(ri_tvalid[1]), .out_tready(ri_tready[1]),

    //tx buffering -- used for insertion of axi_fifo_tx_packet_buff
    .tx_tdata_bo(tx_tdata_bo[1]), .tx_tlast_bo(tx_tlast_bo[1]), .tx_tvalid_bo(tx_tvalid_bo[1]), .tx_tready_bo(tx_tready_bo[1]),
    .tx_tdata_bi(tx_tdata_bi[1]), .tx_tlast_bi(tx_tlast_bi[1]), .tx_tvalid_bi(tx_tvalid_bi[1]), .tx_tready_bi(tx_tready_bi[1]),

    .pps(pps), .sync_dacs(),
    .debug()
  );

endmodule // e300_core
