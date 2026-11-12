Class HD.Trace.TestProduction Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="HD.Trace.TestProduction" TestingEnabled="true" LogGeneralTraceEvents="true">
<Item Name="TraceTestService" ClassName="HD.Service" PoolSize="0" Enabled="true"/>
<Item Name="AgentReview" ClassName="HD.AgentOperation" PoolSize="2" Enabled="true"/>
<Item Name="ModelTrace" ClassName="HD.Trace.Sink" PoolSize="1" Enabled="true"/>
<Item Name="ToolTrace" ClassName="HD.Trace.Sink" PoolSize="1" Enabled="true"/>
<Item Name="RunTrace" ClassName="HD.Trace.GatedSink" PoolSize="1" Enabled="true"/>
</Production>
}
}
