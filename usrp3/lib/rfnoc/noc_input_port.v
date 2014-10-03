
// NoC input port
//   Implements destination flow control for a single port

module noc_input_port
  #(parameter PORT_NUM = 0,
    parameter STR_SINK_FIFOSIZE = 10)
   (input clk, input reset,

    input set_stb, input [7:0] set_addr, input [31:0] set_data,
    
    // To/From NoC Shell
    input [63:0] datain_tdata, input datain_tlast, input datain_tvalid, output datain_tready,
    output [63:0] fcout_tdata, output fcout_tlast, output fcout_tvalid, output fcout_tready,
    
    // To Stream Sink
    output [63:0] str_sink_tdata, output str_sink_tlast, output str_sink_tvalid, input str_sink_tready    
    );

   localparam SB_FCPG = 2;  // 2 regs
   localparam SB_CLEAR_TX_FC = 4;  // 1 reg

   axi_fifo_cascade #(.WIDTH(65), .SIZE(STR_SINK_FIFOSIZE)) str_sink_fifo
     (.clk(clk), .reset(reset), .clear(1'b0),
      .i_tdata({datain_tlast,datain_tdata}), .i_tvalid(datain_tvalid), .i_tready(datain_tready),
      .o_tdata({str_sink_tlast,str_sink_tdata}), .o_tvalid(str_sink_tvalid), .o_tready(str_sink_tready),
      .space(), .occupied());

   reg [11:0] 	 seqnum_hold;
   reg [31:0] 	 sid_hold;
   reg 		 firstline;
   
   always @(posedge clk)
     if(reset)
       firstline <= 1'b1;
     else if(str_sink_tvalid & str_sink_tready)
       firstline <= str_sink_tlast;

   always @(posedge clk)
     if(str_sink_tvalid & str_sink_tready & firstline)
       begin
	  seqnum_hold <= str_sink_tdata[59:48];
	  sid_hold <= str_sink_tdata[31:0];
       end

   wire clear_tx_fc;
   
   setting_reg #(.my_addr(SB_CLEAR_TX_FC+PORT_NUM*4), .at_reset(0)) sr_clear_tx_fc
     (.clk(clk),.rst(reset),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(),.changed(clear_tx_fc));

   tx_responder #(.BASE(SB_FCPG+PORT_NUM*4), .USE_TIME(0)) str_sink_fc_gen
     (.clk(clk), .reset(reset), .clear(clear_tx_fc),
      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
      .ack(1'b0), .error(1'b0), .packet_consumed(str_sink_tlast & str_sink_tvalid & str_sink_tready),
      .seqnum(seqnum_hold), .error_code(64'd0), .sid(sid_hold),
      .vita_time(64'd0),
      .o_tdata(fcout_tdata), .o_tlast(fcout_tlast), .o_tvalid(fcout_tvalid), .o_tready(fcout_tready));

endmodule // noc_input_port
