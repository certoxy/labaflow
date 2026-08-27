import SharedSidebar from "../SharedSidebar";

export default function PickupDeliveryLayout({children}:{children:React.ReactNode}){
 return <div className="appShell"><SharedSidebar active="dispatch"/>{children}</div>;
}
