// Copyright 2021 ETH Zurich and University of Bologna.
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Fabian Schuiki <fschuiki@iis.ee.ethz.ch>


/// A register with handshakes that completely cuts any combinational paths
/// between the input and output. This spill register can be flushed.
module spill_register_flushable #(
  parameter type T           = logic,
  parameter bit  Bypass      = 1'b0   // make this spill register transparent
) (
  input  logic clk_i   ,
  input  logic rst_ni  ,
  input  logic valid_i ,
  input  logic flush_i ,
  output logic ready_o ,
  input  T     data_i  ,
  output logic valid_o ,
  input  logic ready_i ,
  output T     data_o
);

  if (Bypass) begin : gen_bypass
    assign valid_o = valid_i;
    assign ready_o = ready_i;
    assign data_o  = data_i;
  end else begin : gen_spill_reg
    // The A register.
    // Force D-mux (no CE) on the wide data flop.
    //(* direct_enable = "false", DONT_TOUCH = "true" *) 
    T a_data_q;
    logic a_full_q;
    logic a_fill, a_drain;

    //(* keep = "true" *) 
    T a_data_q_next;
    assign a_data_q_next = a_fill_drv ? data_i : a_data_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin : ps_a_data
      if (!rst_ni)
        a_data_q <= T'('0);
      //else if (a_fill)
      //  a_data_q <= data_i;
      else
        a_data_q <= a_data_q_next;
    end

    logic a_full_q_next;
    assign a_full_q_next = (a_fill_drv || a_drain_drv) ? a_fill : a_full_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin : ps_a_full
      if (!rst_ni)
        a_full_q <= 0;
      //else if (a_fill || a_drain)
      //  a_full_q <= a_fill;
      else
        a_full_q <= a_full_q_next;
    end

    // The B register.
    // Force D-mux (no CE) on the wide data flop.
    //(* direct_enable = "false", DONT_TOUCH = "true" *) 
    T b_data_q;
    logic b_full_q;
    logic b_fill, b_drain;

    //(* keep = "true" *) 
    T b_data_q_next;
    assign b_data_q_next = b_fill_drv ? a_data_q : b_data_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin : ps_b_data
      if (!rst_ni)
        b_data_q <= T'('0);
      //else if (b_fill)
      //  b_data_q <= a_data_q;
      else
        b_data_q <= b_data_q_next;
    end

    logic b_full_q_next;
    assign b_full_q_next = (b_fill_drv || b_drain_drv) ? b_fill : b_full_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin : ps_b_full
      if (!rst_ni)
        b_full_q <= 0;
      //else if (b_fill || b_drain)
      //  b_full_q <= b_fill;
      else
        b_full_q <= b_full_q_next;
    end

    // Fill the A register when the A or B register is empty. Drain the A register
    // whenever it is full and being filled, or if a flush is requested.
    assign a_fill_c = valid_i && ready_o && (!flush_i);
    assign a_drain_c = (a_full_q && !b_full_q) || flush_i;

    // Fill the B register whenever the A register is drained, but the downstream
    // circuit is not ready. Drain the B register whenever it is full and the
    // downstream circuit is ready, or if a flush is requested.
    assign b_fill_c = a_drain && (!ready_i) && (!flush_i);
    assign b_drain_c = (b_full_q && ready_i) || flush_i;

    // Register local controls for timing
    (* max_fanout = 16 *) logic a_fill_ce,  a_drain_ce;
    (* max_fanout = 16 *) logic b_fill_ce,  b_drain_ce;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        a_fill_ce  <= 1'b0;
        a_drain_ce <= 1'b0;
        b_fill_ce  <= 1'b0;
        b_drain_ce <= 1'b0;
      end else begin
        a_fill_ce  <= a_fill_c;
        a_drain_ce <= a_drain_c;
        b_fill_ce  <= b_fill_c;
        b_drain_ce <= b_drain_c;
      end
    end
    // Using separate nets avoids the CE signals being optimized away.
    (* max_fanout = 16 *) logic a_fill_drv  = a_fill_ce;
    (* max_fanout = 16 *) logic a_drain_drv = a_drain_ce;
    (* max_fanout = 16 *) logic b_fill_drv  = b_fill_ce;
    (* max_fanout = 16 *) logic b_drain_drv = b_drain_ce;

    // We can accept input as long as register B is not full.
    // Note: flush_i and valid_i must not be high at the same time,
    // otherwise an invalid handshake may occur
    assign ready_o = !a_full_q || !b_full_q;

    // The unit provides output as long as one of the registers is filled.
    assign valid_o = a_full_q | b_full_q;

    // We empty the spill register before the slice register.
    assign data_o = b_full_q ? b_data_q : a_data_q;

    `ifndef SYNTHESIS
    `ifndef COMMON_CELLS_ASSERTS_OFF
    flush_valid : assert property (
      @(posedge clk_i) disable iff (~rst_ni) (flush_i |-> ~valid_i)) else
      $warning("Trying to flush and feed the spill register simultaneously. You will lose data!");
   `endif
     `endif
  end
endmodule
